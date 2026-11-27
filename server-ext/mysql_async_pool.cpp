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
// Worker zero is reserved for progress writes and never serves an editor transaction.
static const int PROGRESS_WORKER = 0;
static const int NO_WORKER = -1;
// Editor transactions hold row locks, so neither silence nor total time may last long.
static const int SESSION_IDLE_TIMEOUT_MS = 10000;
static const int SESSION_LIFETIME_MS = 120000;
// A statement may wait while every non-progress worker is busy before it can bind one.
static const int SESSION_STATEMENT_WAIT_MS = 30000;

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
    int sessionId;          // 0 for independent jobs
    bool endsSession;       // COMMIT or ROLLBACK that closes the session
    bool commitsSession;
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

enum SessionState {
    SESSION_CLOSED = 0,
    SESSION_OPEN = 1,      // accepting statements
    SESSION_ENDING = 2,    // COMMIT or ROLLBACK queued; no more statements
    SESSION_ABANDONED = 3  // timed out or map changed; the bound worker rolls it back
};

// The pool lock protects every field. Only the bound worker uses its connection.
struct Session {
    int id;
    SessionState state;
    int workerIndex;
    bool transactionStarted;
    bool failed;            // the transaction can no longer commit
    long long openedMs;
    long long lastActivityMs;
};
static Session session = {0, SESSION_CLOSED, NO_WORKER, false, false, 0, 0};
static int nextSessionId = 0;

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

static void closeSession() { // mutex held
    session.state = SESSION_CLOSED;
    session.workerIndex = NO_WORKER;
    session.transactionStarted = false;
    session.failed = false;
}

static bool sessionJobPending() { // mutex held
    for(Job *pendingJob = head; pendingJob; pendingJob = pendingJob->next) {
        if(pendingJob->sessionId == session.id && pendingJob->state != JOB_COMPLETE) {
            return true;
        }
    }
    return false;
}

// Stop accepting statements and release queued ones. An unbound session has no
// transaction yet; a bound worker rolls back before the session closes.
static void abandonSession() { // mutex held
    for(Job *pendingJob = head, *next; pendingJob; pendingJob = next) {
        next = pendingJob->next;
        if(pendingJob->sessionId == session.id && pendingJob->state == JOB_QUEUED) {
            finishJob(pendingJob, SQL_EXPIRED, 0);
        }
    }
    if(session.workerIndex == NO_WORKER) {
        closeSession();
    } else {
        session.state = SESSION_ABANDONED;
    }
}

// A transaction must not keep its locks after its owner went quiet or took too long.
static void expireSession(long long currentTimeMs) { // mutex held
    if(session.state != SESSION_OPEN) {
        return;
    }
    const bool idle = currentTimeMs - session.lastActivityMs > SESSION_IDLE_TIMEOUT_MS &&
                      !sessionJobPending();
    const bool overlong = currentTimeMs - session.openedMs > SESSION_LIFETIME_MS;
    if(idle || overlong) {
        abandonSession();
    }
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
    bool sessionEndExpired = false;
    for(Job *pendingJob = head, *next; pendingJob; pendingJob = next) {
        next = pendingJob->next;
        if(pendingJob->state == JOB_QUEUED && currentTimeMs >= pendingJob->deadlineMs) {
            // An unrun statement leaves its transaction incomplete; it may not commit.
            if(pendingJob->sessionId && pendingJob->sessionId == session.id) {
                session.failed = true;
                sessionEndExpired = sessionEndExpired || pendingJob->endsSession;
            }
            finishJob(pendingJob, SQL_EXPIRED, 0);
        }
    }
    // Abandon after the scan: abandoning finishes other queued jobs of the session.
    if(sessionEndExpired) {
        abandonSession();
    }
    expireSession(currentTimeMs);
    // A bound worker serves only its transaction, in submission order.
    if(session.workerIndex == workerIndex) {
        for(Job *pendingJob = head; pendingJob; pendingJob = pendingJob->next) {
            if(pendingJob->state == JOB_QUEUED && pendingJob->sessionId == session.id) {
                return pendingJob;
            }
        }
        return NULL;
    }
    // The first statement of a transaction binds this idle non-progress worker.
    if(session.workerIndex == NO_WORKER && workerIndex != PROGRESS_WORKER &&
       session.state != SESSION_CLOSED) {
        for(Job *pendingJob = head; pendingJob; pendingJob = pendingJob->next) {
            if(pendingJob->state == JOB_QUEUED && pendingJob->sessionId == session.id) {
                session.workerIndex = workerIndex;
                return pendingJob;
            }
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
            if(pendingJob->sessionId) {
                continue;
            }
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

// Session state the bound worker needs, copied under the pool lock.
struct SessionStep {
    bool transactionStarted;
    bool failed;
    bool endsSession;
    bool commits;
};

struct SessionExecution {
    SqlExecution execution;
    bool startedTransaction;
    bool transactionFailed;   // the transaction no longer exists or may not commit
};

static void rollbackConnection(Worker *worker) {
    if(worker->db && mysql_query(worker->db, "ROLLBACK")) {
        // Closing the connection also discards its transaction.
        mysql_close(worker->db);
        worker->db = NULL;
    }
}

// Start the transaction on a fresh or verified connection. Never reconnect once a
// transaction is open: a new connection would silently run outside it.
static bool startSessionTransaction(Worker *worker, SqlExecution *execution) {
    if(!worker->db || mysql_ping(worker->db)) {
        if(worker->db) {
            mysql_close(worker->db);
        }
        worker->db = connectWorker();
    }
    if(!worker->db) {
        execution->outcome = SQL_UNAVAILABLE;
        return false;
    }
    // Like independent writes there is no SELECT deadline; innodb_lock_wait_timeout
    // bounds waiting for locks, and the session lifetime bounds the transaction.
    if(mysql_query(worker->db, "SET SESSION max_execution_time=0") ||
       mysql_query(worker->db, "START TRANSACTION")) {
        execution->error = mysql_errno(worker->db);
        execution->outcome = SQL_UNAVAILABLE;
        return false;
    }
    return true;
}

// Run one statement of the bound transaction. Unlike independent jobs, the
// transaction stays open between statements until COMMIT or ROLLBACK.
static SessionExecution executeSessionJob(Worker *worker, Job *job, const SessionStep &step) {
    SessionExecution result = {{SQL_OK, 0, NULL}, false, false};
    SqlExecution &execution = result.execution;
    if(step.endsSession && !step.transactionStarted) {
        // No statement ran, so there is nothing to commit or roll back.
        execution.outcome = step.commits && step.failed ? SQL_ERROR : SQL_OK;
        return result;
    }
    if(step.failed) {
        // After a failure nothing more may run, and a requested COMMIT rolls back.
        if(step.endsSession) {
            rollbackConnection(worker);
        }
        execution.outcome = step.endsSession && !step.commits ? SQL_OK : SQL_ERROR;
        return result;
    }
    if(!step.transactionStarted) {
        if(!startSessionTransaction(worker, &execution)) {
            result.transactionFailed = true;
            return result;
        }
        result.startedTransaction = true;
    } else if(!worker->db) {
        execution.outcome = SQL_UNAVAILABLE;
        result.transactionFailed = true;
        return result;
    }
    if(mysql_query(worker->db, job->query)) {
        execution.error = mysql_errno(worker->db);
    } else {
        execution.result = collectResults(worker->db, job->retainResult, &execution.error);
    }
    if(execution.error) {
        const bool lost = connectionLost(execution.error);
        execution.outcome = lost && step.commits ? SQL_UNKNOWN : SQL_ERROR;
        // Statements queued behind this one may depend on it, and MySQL may already
        // have rolled back (for example after a deadlock), so it cannot commit.
        result.transactionFailed = true;
        if(lost) {
            mysql_close(worker->db);
            worker->db = NULL;
        }
    }
    // A failed COMMIT must not leave the connection inside the transaction.
    if(step.endsSession && worker->db && (worker->db->server_status & SERVER_STATUS_IN_TRANS)) {
        rollbackConnection(worker);
    }
    return result;
}

// Run the selected session job outside the lock and record its effect on the session.
static void runSessionJob(Worker *worker, Job *job) { // mutex held on entry and exit
    SessionStep step = {session.transactionStarted, session.failed, job->endsSession,
                        job->commitsSession};
    pthread_mutex_unlock(&mutex);
    SessionExecution sessionExecution = executeSessionJob(worker, job, step);
    pthread_mutex_lock(&mutex);
    if(sessionExecution.startedTransaction) {
        session.transactionStarted = true;
    }
    if(sessionExecution.transactionFailed) {
        session.failed = true;
    }
    session.lastActivityMs = nowMs();
    if(job->endsSession) {
        closeSession();
    }
    job->result = sessionExecution.execution.result;
    finishJob(job, sessionExecution.execution.outcome, sessionExecution.execution.error);
}

// Roll back an abandoned transaction on its bound worker, then free that worker.
static void settleAbandonedSession(Worker *worker) { // mutex held on entry and exit
    const bool hasTransaction = session.transactionStarted;
    pthread_mutex_unlock(&mutex);
    if(hasTransaction) {
        rollbackConnection(worker);
    }
    pthread_mutex_lock(&mutex);
    closeSession();
    pthread_cond_broadcast(&changed);
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
        if(session.workerIndex == workerIndex && session.state == SESSION_ABANDONED &&
           !sessionJobPending()) {
            settleAbandonedSession(worker);
            continue;
        }
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
        if(job->sessionId) {
            runSessionJob(worker, job);
            continue;
        }
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

// Fields that only session statements set; independent jobs use NO_SESSION.
struct SessionJobFields {
    int sessionId;
    bool endsSession;
    bool commitsSession;
};
static const SessionJobFields NO_SESSION = {0, false, false};

// Reserve both a job slot and query storage before accepting ownership.
// The caller holds the pool lock and has validated the arguments.
static int enqueueJob(const char *query, bool retainResult, int policy, const char *orderingKey,
                      const char *scope, int waitMs, const SessionJobFields &sessionFields) {
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
    job->sessionId = sessionFields.sessionId;
    job->endsSession = sessionFields.endsSession;
    job->commitsSession = sessionFields.commitsSession;
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
    pthread_cond_broadcast(&changed);
    return job->id;
}

static bool validQueryText(const char *query) {
    return query && strlen(query) <= MAX_QUERY_BYTES;
}

int sqlPoolSubmit(const char *query, bool retainResult, int policy, const char *orderingKey,
                  const char *scope, int waitMs) {
    if(!validQueryText(query) || !orderingKey || !scope) {
        return -SQL_INVALID;
    }
    if(strlen(orderingKey) > MAX_SCOPE_KEY_BYTES || strlen(scope) > MAX_SCOPE_KEY_BYTES) {
        return -SQL_INVALID;
    }
    if(policy < SQL_PROGRESS || policy > SQL_WRITE) {
        return -SQL_INVALID;
    }
    if(waitMs < 1 || waitMs > MAX_QUEUE_WAIT_MS) {
        return -SQL_INVALID;
    }
    pthread_mutex_lock(&mutex);
    int id = enqueueJob(query, retainResult, policy, orderingKey, scope, waitMs, NO_SESSION);
    pthread_mutex_unlock(&mutex);
    return id;
}

int sqlPoolBeginSession() {
    pthread_mutex_lock(&mutex);
    int result;
    if(!initialized) {
        result = -SQL_UNAVAILABLE;
    } else if(session.state != SESSION_CLOSED) {
        result = -SQL_BUSY;
    } else {
        nextSessionId = nextSessionId == INT_MAX ? 1 : nextSessionId + 1;
        long long currentTimeMs = nowMs();
        session = {nextSessionId, SESSION_OPEN, NO_WORKER, false, false, currentTimeMs,
                   currentTimeMs};
        result = session.id;
    }
    pthread_mutex_unlock(&mutex);
    return result;
}

int sqlPoolSubmitSession(int sessionId, const char *query, bool retainResult) {
    if(!validQueryText(query)) {
        return -SQL_INVALID;
    }
    pthread_mutex_lock(&mutex);
    int id = -SQL_EXPIRED;
    if(initialized && session.state == SESSION_OPEN && session.id == sessionId) {
        const SessionJobFields statement = {sessionId, false, false};
        id = enqueueJob(query, retainResult, SQL_WRITE, "", "", SESSION_STATEMENT_WAIT_MS,
                        statement);
        if(id > 0) {
            session.lastActivityMs = nowMs();
        }
    }
    pthread_mutex_unlock(&mutex);
    return id;
}

int sqlPoolEndSession(int sessionId, bool commit) {
    pthread_mutex_lock(&mutex);
    int id = -SQL_EXPIRED;
    if(initialized && session.state == SESSION_OPEN && session.id == sessionId) {
        const SessionJobFields ending = {sessionId, true, commit};
        id = enqueueJob(commit ? "COMMIT" : "ROLLBACK", false, SQL_WRITE, "", "",
                        SESSION_STATEMENT_WAIT_MS, ending);
        if(id > 0) {
            session.state = SESSION_ENDING;
            session.lastActivityMs = nowMs();
        }
    }
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

// The caller holds the pool lock. An active worker retains its connection and
// result ownership until completion; queued work can be released immediately.
static void cancelJob(Job *job, bool discardCompletion) {
    job->cancelled = true;
    job->discardCompletion = discardCompletion;
    if(job->state == JOB_QUEUED) {
        finishJob(job, SQL_CANCELLED, 0);
    } else if(job->state == JOB_COMPLETE) {
        if(job->result) {
            mysql_free_result(job->result);
            job->result = NULL;
        }
        if(job->completion.outcome != SQL_CANCELLED) {
            if(job->completion.outcome == SQL_OK) {
                stats.succeeded--;
            } else {
                stats.failed--;
                if(job->completion.outcome == SQL_UNKNOWN) {
                    stats.unknown--;
                }
                if(job->completion.outcome == SQL_EXPIRED) {
                    stats.expired--;
                }
            }
            stats.cancelled++;
        }
        job->completion.outcome = SQL_CANCELLED;
        if(discardCompletion) {
            stats.completed--;
            unlinkJob(job);
        }
    }
}

bool sqlPoolCancelRead(int id, SqlCompletionHandling completionHandling) {
    pthread_mutex_lock(&mutex);
    bool cancelled = false;
    for(Job *job = head; job; job = job->next) {
        if(job->id != id) {
            continue;
        }
        if(job->policy == SQL_READ || job->policy == SQL_MENU) {
            cancelJob(job, completionHandling == SqlCompletionHandling::Discard);
            cancelled = true;
        }
        break;
    }
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
    return cancelled;
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
        cancelJob(pendingJob, discardCompletion);
    }
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
}

void sqlPoolNewMap() {
    sqlPoolCancel("", SqlScopeMatch::Prefix, SqlCompletionHandling::Discard);
    // The old map's editor cannot finish an open transaction. A queued COMMIT settles.
    pthread_mutex_lock(&mutex);
    if(session.state == SESSION_OPEN) {
        abandonSession();
    }
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
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
    // Closing the worker connections already discarded any open transaction.
    closeSession();
    workerCount = 0;
    menuJobCount = 0;
    stopping = false;
    pthread_mutex_unlock(&mutex);
}
