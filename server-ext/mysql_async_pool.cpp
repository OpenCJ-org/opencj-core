#include "mysql_async_pool.hpp"
#include <mysql/errmsg.h>
#include <pthread.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

// Caps cover queued, running AND uncollected completions. Query storage is exact
// length, not a 10 KiB allocation for every tiny request.
static const int MAX_OUTSTANDING_JOBS = 512;
static const int NON_PROGRESS_JOB_LIMIT = 384;
static const int MENU_JOB_LIMIT = 64;
static const int MAX_QUERY_STORAGE_BYTES = 2 * 1024 * 1024;
static const int NON_PROGRESS_QUERY_BYTES = 1536 * 1024;
static const int MAX_QUERY_BYTES = 10 * 1024;
static const int MAX_SCOPE_KEY_BYTES = 95;
static const int WORKER_COUNT = 4;
static const int MAX_QUEUE_WAIT_MS = 60000;

enum JobState {
    JOB_QUEUED = 0,
    JOB_RUNNING = 1,
    JOB_COMPLETE = 2
};

struct Job {
    Job *next;
    int id;
    int policy;
    JobState state;
    bool retainResult;
    bool cancelled;
    bool discardCompletion;
    char orderingKey[MAX_SCOPE_KEY_BYTES + 1];
    char scope[MAX_SCOPE_KEY_BYTES + 1];
    char *query;
    int queryStorageBytes;
    long long enqueuedMs;
    long long startedMs;
    long long deadlineMs;
    MYSQL_RES *result;
    SqlCompletion completion;
};

struct Worker {
    pthread_t thread;
    MYSQL *db;
    bool created;
    bool ready;
    bool healthy;
};

static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static Job *head = NULL;
static Job *tail = NULL;
static Worker workers[WORKER_COUNT];
static bool initialized = false;
static bool stopping = false;
static bool starting = false;
static char *host = NULL;
static char *user = NULL;
static char *password = NULL;
static char *database = NULL;
static int port = 0;
static int workerCount = 0;
static int nextId = 0;
static int scheduleIndex = 0;
static int menuJobCount = 0;
static SqlPoolStats stats = {};

static long long nowMs() {
    timespec timestamp;
    clock_gettime(CLOCK_MONOTONIC, &timestamp);
    return (long long)timestamp.tv_sec * 1000 + timestamp.tv_nsec / 1000000;
}

static bool connectionLost(unsigned mysqlError) {
    return mysqlError == CR_SERVER_GONE_ERROR || mysqlError == CR_SERVER_LOST ||
           mysqlError == CR_SERVER_LOST_EXTENDED;
}

// Each worker owns its connection; bounded I/O prevents a lost database from
// leaving that worker stuck forever. Do not replay statements after reconnect.
static MYSQL *connectWorker() {
    MYSQL *db = mysql_init(NULL);
    if(!db) {
        return NULL;
    }
    unsigned connectTimeoutSeconds = 3;
    unsigned ioTimeoutSeconds = 2;
    mysql_options(db, MYSQL_OPT_CONNECT_TIMEOUT, &connectTimeoutSeconds);
    mysql_options(db, MYSQL_OPT_READ_TIMEOUT, &ioTimeoutSeconds);
    mysql_options(db, MYSQL_OPT_WRITE_TIMEOUT, &ioTimeoutSeconds);
    // Automatic reconnect is OFF: an uncertain statement is never replayed.
    if(!mysql_real_connect(db, host, user, password, database, port, NULL, 0)) {
        mysql_close(db);
        return NULL;
    }
    if(mysql_query(db, "SET SESSION innodb_lock_wait_timeout=3")) {
        mysql_close(db);
        return NULL;
    }
    return db;
}

static void unlinkJob(Job *job) { // mutex held
    Job *previous = NULL;
    for(Job *pendingJob = head; pendingJob && pendingJob != job; pendingJob = pendingJob->next) {
        previous = pendingJob;
    }
    if(previous) {
        previous->next = job->next;
    } else {
        head = job->next;
    }
    if(tail == job) {
        tail = previous;
    }
    stats.outstanding--;
    if(job->policy == SQL_MENU) {
        menuJobCount--;
    }
    if(job->query) {
        stats.queryBytes -= job->queryStorageBytes;
        free(job->query);
    }
    if(job->result) {
        mysql_free_result(job->result);
    }
    free(job);
}

// Publish completion under the pool lock. A running job stays allocated until
// its worker returns here, even when its consumer has cancelled or gone away.
static void finishJob(Job *job, int outcome, int error) { // mutex held
    if(job->state == JOB_QUEUED) {
        stats.queued--;
    } else if(job->state == JOB_RUNNING) {
        stats.running--;
    }
    job->state = JOB_COMPLETE;
    job->completion.outcome = job->cancelled ? SQL_CANCELLED : outcome;
    job->completion.error = error;
    long long finishedMs = nowMs();
    job->completion.waitMs =
        (int)((job->startedMs ? job->startedMs : finishedMs) - job->enqueuedMs);
    job->completion.executionMs = job->startedMs ? (int)(finishedMs - job->startedMs) : 0;
    if(job->completion.waitMs > stats.maxWaitMs) {
        stats.maxWaitMs = job->completion.waitMs;
    }
    if(job->completion.executionMs > stats.maxExecutionMs) {
        stats.maxExecutionMs = job->completion.executionMs;
    }
    if(job->query) {
        stats.queryBytes -= job->queryStorageBytes;
        free(job->query);
        job->query = NULL;
    }
    if(job->completion.outcome == SQL_OK) {
        stats.succeeded++;
    } else if(job->completion.outcome == SQL_CANCELLED) {
        stats.cancelled++;
    } else {
        stats.failed++;
        if(outcome == SQL_UNKNOWN) {
            stats.unknown++;
        }
        if(outcome == SQL_EXPIRED) {
            stats.expired++;
        }
    }
    if(job->cancelled && job->result) {
        mysql_free_result(job->result);
        job->result = NULL;
    }
    if(job->discardCompletion) {
        unlinkJob(job);
    } else {
        stats.completed++;
    }
    pthread_cond_broadcast(&changed);
}

// The pool lock protects the queue and the ordering decision.
static bool canDispatch(Job *job) {
    if(job->state != JOB_QUEUED) {
        return false;
    }
    if(!job->orderingKey[0]) {
        return true;
    }
    // Earlier accepted work with this key must finish before dispatch, even if
    // it has a lower priority. Completed jobs need not wait for GSC collection.
    for(Job *pendingJob = head; pendingJob != job; pendingJob = pendingJob->next) {
        if(pendingJob->state != JOB_COMPLETE &&
           !strcmp(pendingJob->orderingKey, job->orderingKey)) {
            return false;
        }
    }
    return true;
}

// Expire queued jobs and select work without overtaking an earlier job's key.
// Caller holds the pool lock; completed results still occupy admission slots.
static Job *chooseNextJob(int workerIndex) {
    long long currentTimeMs = nowMs();
    for(Job *pendingJob = head, *next; pendingJob; pendingJob = next) {
        next = pendingJob->next;
        if(pendingJob->state == JOB_QUEUED && currentTimeMs >= pendingJob->deadlineMs) {
            finishJob(pendingJob, SQL_EXPIRED, 0);
        }
    }
    // Worker zero is reserved for progress. Other workers use weighted fair
    // service: progress dominates without starving reads or background uploads.
    static const int schedulePolicies[] = {SQL_PROGRESS, SQL_PROGRESS, SQL_PROGRESS, SQL_PROGRESS,
                                           SQL_READ,     SQL_PROGRESS, SQL_PROGRESS, SQL_BACKGROUND,
                                           SQL_PROGRESS, SQL_MENU};
    static const int scheduleLength = sizeof(schedulePolicies) / sizeof(schedulePolicies[0]);
    int preferredPolicy = SQL_PROGRESS;
    if(workerIndex != 0) {
        preferredPolicy = schedulePolicies[scheduleIndex];
        // Keep the counter inside this cycle even after months of server uptime.
        scheduleIndex = (scheduleIndex + 1) % scheduleLength;
    }
    for(int pass = 0; pass < 2; pass++) {
        for(Job *pendingJob = head; pendingJob; pendingJob = pendingJob->next) {
            int schedulingPolicy = pendingJob->policy == SQL_WRITE ? SQL_READ : pendingJob->policy;
            if(workerIndex == 0 && schedulingPolicy != SQL_PROGRESS) {
                continue;
            }
            if(pass == 0 && schedulingPolicy != preferredPolicy) {
                continue;
            }
            if(canDispatch(pendingJob)) {
                return pendingJob;
            }
        }
    }
    return NULL;
}

// Drain every response so the next job starts with a clean connection.
// Return only the first result when requested; the caller owns that result.
static MYSQL_RES *collectResults(MYSQL *db, bool retainResult, int *error) {
    MYSQL_RES *first = mysql_store_result(db);
    *error = mysql_errno(db);
    while(!*error && mysql_more_results(db)) {
        int next = mysql_next_result(db);
        if(next > 0) {
            *error = mysql_errno(db);
            break;
        }
        if(next < 0) {
            break;
        }
        MYSQL_RES *extra = mysql_store_result(db);
        *error = mysql_errno(db);
        if(extra) {
            mysql_free_result(extra);
        }
    }
    if((*error || !retainResult) && first) {
        mysql_free_result(first);
        first = NULL;
    }
    return first;
}

struct SqlExecution {
    int outcome;
    int error;
    MYSQL_RES *result;
};

// Run one statement, drain its responses and clear any unclosed transaction.
// Only the owning worker accesses this connection; no pool lock is held here.
static SqlExecution executeJob(Worker *worker, Job *job) {
    SqlExecution execution = {SQL_OK, 0, NULL};
    if(!worker->db || mysql_ping(worker->db)) {
        if(worker->db) {
            mysql_close(worker->db);
        }
        worker->db = connectWorker();
    }
    if(!worker->db) {
        execution.outcome = SQL_UNAVAILABLE;
    } else {
        bool readOnly = job->policy == SQL_READ || job->policy == SQL_MENU;
        // Server-side SELECT deadline complements bounded socket I/O.
        const char *executionLimitSql =
            readOnly ? "SET SESSION max_execution_time=2000" : "SET SESSION max_execution_time=0";
        if(mysql_query(worker->db, executionLimitSql)) {
            execution.error = mysql_errno(worker->db);
            execution.outcome = SQL_UNAVAILABLE;
        } else if(mysql_query(worker->db, job->query)) {
            execution.error = mysql_errno(worker->db);
            execution.outcome =
                connectionLost(execution.error) && !readOnly ? SQL_UNKNOWN : SQL_ERROR;
        } else {
            execution.result = collectResults(worker->db, job->retainResult, &execution.error);
            if(execution.error) {
                execution.outcome =
                    connectionLost(execution.error) && !readOnly ? SQL_UNKNOWN : SQL_ERROR;
            }
        }
        // A job cannot leak a transaction into the next independent job.
        // A transactional stored procedure must commit/rollback before returning.
        if(worker->db->server_status & SERVER_STATUS_IN_TRANS) {
            mysql_query(worker->db, "ROLLBACK");
            if(execution.result) {
                mysql_free_result(execution.result);
                execution.result = NULL;
            }
            if(execution.outcome == SQL_OK) {
                execution.outcome = SQL_INVALID;
            }
        }
        if(execution.error && connectionLost(execution.error)) {
            mysql_close(worker->db);
            worker->db = NULL;
        }
    }
    return execution;
}

// Own one MySQL connection and execute selected jobs outside the queue lock.
// The job remains in the queue while running so its ordering key stays reserved.
static void *workerMain(void *workerIndexArgument) {
    int workerIndex = (int)(long)workerIndexArgument;
    Worker *worker = &workers[workerIndex];
    bool threadReady = mysql_thread_init() == 0;
    if(threadReady) {
        worker->db = connectWorker();
    }
    pthread_mutex_lock(&mutex);
    worker->healthy = worker->db != NULL;
    worker->ready = true;
    pthread_cond_broadcast(&changed);
    while(starting && !stopping) {
        pthread_cond_wait(&changed, &mutex);
    }
    while(!stopping) {
        Job *job = chooseNextJob(workerIndex);
        if(!job) {
            // Wake for admission/completion/cancellation, or to expire jobs whose
            // ordering dependency is still running on another connection.
            timespec wakeDeadline;
            clock_gettime(CLOCK_REALTIME, &wakeDeadline);
            wakeDeadline.tv_sec++;
            pthread_cond_timedwait(&changed, &mutex, &wakeDeadline);
            continue;
        }
        job->state = JOB_RUNNING;
        job->startedMs = nowMs();
        stats.queued--;
        stats.running++;
        pthread_mutex_unlock(&mutex);
        SqlExecution execution = executeJob(worker, job);
        pthread_mutex_lock(&mutex);
        job->result = execution.result;
        finishJob(job, execution.outcome, execution.error);
    }
    pthread_mutex_unlock(&mutex);
    if(worker->db) {
        mysql_close(worker->db);
        worker->db = NULL;
    }
    if(threadReady) {
        mysql_thread_end();
    }
    return NULL;
}

// Start the fixed-size pool together; a failed worker tears down the whole start.
bool sqlPoolInit(const char *serverHost, const char *serverUser, const char *serverPassword,
                 const char *databaseName, int serverPort, int requestedWorkers) {
    pthread_mutex_lock(&mutex);
    if(initialized) {
        pthread_mutex_unlock(&mutex);
        return true;
    }
    if(requestedWorkers != WORKER_COUNT || starting) {
        pthread_mutex_unlock(&mutex);
        return false;
    }
    mysql_library_init(0, NULL, NULL);
    host = strdup(serverHost);
    user = strdup(serverUser);
    password = strdup(serverPassword);
    database = strdup(databaseName);
    port = serverPort;
    starting = true;
    stopping = false;
    workerCount = requestedWorkers;
    bool connected = host && user && password && database;
    memset(workers, 0, sizeof(workers));
    for(int i = 0; connected && i < requestedWorkers; i++) {
        connected = pthread_create(&workers[i].thread, NULL, workerMain, (void *)(long)i) == 0;
        workers[i].created = connected;
    }
    bool allWorkersReady = false;
    while(connected && !allWorkersReady) {
        allWorkersReady = true;
        for(int i = 0; i < requestedWorkers; i++) {
            if(!workers[i].ready) {
                allWorkersReady = false;
            }
        }
        if(!allWorkersReady) {
            pthread_cond_wait(&changed, &mutex);
        }
    }
    for(int i = 0; i < requestedWorkers; i++) {
        if(!workers[i].healthy) {
            connected = false;
        }
    }
    initialized = connected;
    starting = false;
    stopping = !connected;
    stats.workers = connected ? requestedWorkers : 0;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
    if(!connected) {
        sqlPoolShutdown();
    }
    return connected;
}

// Reserve both a job slot and query storage before accepting ownership.
int sqlPoolSubmit(const char *query, bool retainResult, int policy, const char *orderingKey,
                  const char *scope, int waitMs) {
    if(!query || !orderingKey || !scope) {
        return -SQL_INVALID;
    }
    if(strlen(query) > MAX_QUERY_BYTES || strlen(orderingKey) > MAX_SCOPE_KEY_BYTES ||
       strlen(scope) > MAX_SCOPE_KEY_BYTES) {
        return -SQL_INVALID;
    }
    if(policy < SQL_PROGRESS || policy > SQL_WRITE) {
        return -SQL_INVALID;
    }
    if(waitMs < 1 || waitMs > MAX_QUEUE_WAIT_MS) {
        return -SQL_INVALID;
    }
    pthread_mutex_lock(&mutex);
    int queryStorageBytes = strlen(query) + 1;
    int error = 0;
    if(!initialized) {
        error = SQL_UNAVAILABLE;
    } else {
        const bool poolFull = stats.outstanding >= MAX_OUTSTANDING_JOBS ||
                              stats.queryBytes + queryStorageBytes > MAX_QUERY_STORAGE_BYTES;
        const bool progressReserveReached =
            policy != SQL_PROGRESS &&
            (stats.outstanding >= NON_PROGRESS_JOB_LIMIT ||
             stats.queryBytes + queryStorageBytes > NON_PROGRESS_QUERY_BYTES);
        const bool menuLimitReached = policy == SQL_MENU && menuJobCount >= MENU_JOB_LIMIT;
        if(poolFull || progressReserveReached || menuLimitReached) {
            error = SQL_BUSY;
        }
    }
    if(error) {
        stats.rejected++;
        pthread_mutex_unlock(&mutex);
        return -error;
    }
    Job *job = (Job *)calloc(1, sizeof(Job));
    if(job) {
        job->query = (char *)malloc(queryStorageBytes);
    }
    if(!job || !job->query) {
        if(job) {
            free(job);
        }
        stats.rejected++;
        pthread_mutex_unlock(&mutex);
        return -SQL_BUSY;
    }
    do {
        nextId = nextId == INT_MAX ? 1 : nextId + 1;
        bool used = false;
        for(Job *pendingJob = head; pendingJob; pendingJob = pendingJob->next) {
            if(pendingJob->id == nextId) {
                used = true;
                break;
            }
        }
        if(!used) {
            break;
        }
    } while(true);
    job->id = nextId;
    job->policy = policy;
    job->retainResult = retainResult;
    job->queryStorageBytes = queryStorageBytes;
    strcpy(job->query, query);
    strcpy(job->orderingKey, orderingKey);
    strcpy(job->scope, scope);
    job->enqueuedMs = nowMs();
    job->deadlineMs = job->enqueuedMs + waitMs;
    if(tail) {
        tail->next = job;
    } else {
        head = job;
    }
    tail = job;
    stats.accepted++;
    stats.outstanding++;
    stats.queued++;
    stats.queryBytes += queryStorageBytes;
    if(policy == SQL_MENU) {
        menuJobCount++;
    }
    if(stats.outstanding > stats.peakJobs) {
        stats.peakJobs = stats.outstanding;
    }
    if(stats.queryBytes > stats.peakBytes) {
        stats.peakBytes = stats.queryBytes;
    }
    int id = job->id;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
    return id;
}

int sqlPoolDone(int *completedIds, int capacity) {
    pthread_mutex_lock(&mutex);
    int completedCount = 0;
    for(Job *pendingJob = head; pendingJob && completedCount < capacity;
        pendingJob = pendingJob->next) {
        if(pendingJob->state == JOB_COMPLETE) {
            completedIds[completedCount++] = pendingJob->id;
        }
    }
    pthread_mutex_unlock(&mutex);
    return completedCount;
}

bool sqlPoolStatus(int id, SqlCompletion *completion) {
    pthread_mutex_lock(&mutex);
    bool found = false;
    for(Job *pendingJob = head; pendingJob; pendingJob = pendingJob->next) {
        if(pendingJob->id == id && pendingJob->state == JOB_COMPLETE) {
            *completion = pendingJob->completion;
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&mutex);
    return found;
}

bool sqlPoolPeek(int id, MYSQL_RES **result, SqlCompletion *completion) {
    pthread_mutex_lock(&mutex);
    bool found = false;
    for(Job *pendingJob = head; pendingJob; pendingJob = pendingJob->next) {
        if(pendingJob->id == id && pendingJob->state == JOB_COMPLETE) {
            *completion = pendingJob->completion;
            *result = pendingJob->result;
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&mutex);
    return found;
}

bool sqlPoolTake(int id, MYSQL_RES **result, SqlCompletion *completion) {
    pthread_mutex_lock(&mutex);
    bool found = false;
    for(Job *pendingJob = head; pendingJob; pendingJob = pendingJob->next) {
        if(pendingJob->id == id && pendingJob->state == JOB_COMPLETE) {
            *completion = pendingJob->completion;
            *result = pendingJob->result;
            pendingJob->result = NULL;
            stats.completed--;
            unlinkJob(pendingJob);
            found = true;
            break;
        }
    }
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
    return found;
}

// Cancel only menu reads: accepted writes must still settle. Never close a
// connection from this thread while its worker is using the MySQL client.
void sqlPoolCancel(const char *scope, SqlScopeMatch scopeMatch,
                   SqlCompletionHandling completionHandling) {
    const bool prefix = scopeMatch == SqlScopeMatch::Prefix;
    const bool discardCompletion = completionHandling == SqlCompletionHandling::Discard;
    pthread_mutex_lock(&mutex);
    for(Job *pendingJob = head, *next; pendingJob; pendingJob = next) {
        next = pendingJob->next;
        if(pendingJob->policy != SQL_MENU || !pendingJob->scope[0]) {
            continue;
        }
        bool match = prefix ? !strncmp(pendingJob->scope, scope, strlen(scope))
                            : !strcmp(pendingJob->scope, scope);
        if(!match) {
            continue;
        }
        pendingJob->cancelled = true;
        pendingJob->discardCompletion = discardCompletion;
        if(pendingJob->state == JOB_QUEUED) {
            finishJob(pendingJob, SQL_CANCELLED, 0);
        } else if(pendingJob->state == JOB_COMPLETE) {
            if(pendingJob->result) {
                mysql_free_result(pendingJob->result);
                pendingJob->result = NULL;
            }
            if(pendingJob->completion.outcome != SQL_CANCELLED) {
                if(pendingJob->completion.outcome == SQL_OK) {
                    stats.succeeded--;
                } else {
                    stats.failed--;
                    if(pendingJob->completion.outcome == SQL_UNKNOWN) {
                        stats.unknown--;
                    }
                    if(pendingJob->completion.outcome == SQL_EXPIRED) {
                        stats.expired--;
                    }
                }
                stats.cancelled++;
            }
            pendingJob->completion.outcome = SQL_CANCELLED;
            if(discardCompletion) {
                stats.completed--;
                unlinkJob(pendingJob);
            }
        }
    }
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
}

void sqlPoolNewMap() {
    sqlPoolCancel("", SqlScopeMatch::Prefix, SqlCompletionHandling::Discard);
}

SqlPoolStats sqlPoolStats() {
    pthread_mutex_lock(&mutex);
    SqlPoolStats snapshot = stats;
    snapshot.oldestWaitMs = 0;
    long long currentTimeMs = nowMs();
    for(Job *pendingJob = head; pendingJob; pendingJob = pendingJob->next) {
        if(pendingJob->state == JOB_QUEUED &&
           currentTimeMs - pendingJob->enqueuedMs > snapshot.oldestWaitMs) {
            snapshot.oldestWaitMs = (int)(currentTimeMs - pendingJob->enqueuedMs);
        }
    }
    pthread_mutex_unlock(&mutex);
    return snapshot;
}

// Stop workers before freeing jobs or credentials that they may still read.
void sqlPoolShutdown() {
    pthread_mutex_lock(&mutex);
    stopping = true;
    starting = false;
    initialized = false;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
    for(int i = 0; i < workerCount; i++) {
        if(workers[i].created) {
            pthread_join(workers[i].thread, NULL);
        }
    }
    pthread_mutex_lock(&mutex);
    while(head) {
        unlinkJob(head);
    }
    free(host);
    free(user);
    free(password);
    free(database);
    host = NULL;
    user = NULL;
    password = NULL;
    database = NULL;
    memset(workers, 0, sizeof(workers));
    memset(&stats, 0, sizeof(stats));
    workerCount = 0;
    menuJobCount = 0;
    stopping = false;
    pthread_mutex_unlock(&mutex);
}
