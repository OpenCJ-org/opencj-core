#include "mysql_async_pool.hpp"
#include <mysql/errmsg.h>
#include <pthread.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

// Caps cover queued, running AND uncollected completions. Query storage is exact
// length, not a 10 KiB allocation for every tiny request.
static const int MAX_JOBS = 512;
static const int NORMAL_JOBS = 384;
static const int MENU_JOBS = 64;
static const int MAX_BYTES = 2 * 1024 * 1024;
static const int NORMAL_BYTES = 1536 * 1024;
static const int MAX_QUERY = 10 * 1024;
static const int MAX_KEY = 95;
static const int MAX_WORKERS = 4;

struct Job {
    Job *next;
    int id;
    int policy;
    int state; // queued=0, running=1, complete=2
    bool save;
    bool cancelled;
    bool forget;
    char key[MAX_KEY + 1];
    char scope[MAX_KEY + 1];
    char *query;
    int bytes;
    long long enqueued;
    long long started;
    long long deadline;
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
static Worker workers[MAX_WORKERS];
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
static int schedule = 0;
static int menus = 0;
static SqlPoolStats stats = {};

static long long nowMs() {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static bool lost(unsigned n) {
    return n == CR_SERVER_GONE_ERROR || n == CR_SERVER_LOST || n == CR_SERVER_LOST_EXTENDED;
}

static MYSQL *connectWorker() {
    MYSQL *db = mysql_init(NULL);
    if(!db) {
        return NULL;
    }
    unsigned connect = 3;
    unsigned io = 2;
    mysql_options(db, MYSQL_OPT_CONNECT_TIMEOUT, &connect);
    mysql_options(db, MYSQL_OPT_READ_TIMEOUT, &io);
    mysql_options(db, MYSQL_OPT_WRITE_TIMEOUT, &io);
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
    for(Job *p = head; p && p != job; p = p->next) {
        previous = p;
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
        menus--;
    }
    if(job->query) {
        stats.queryBytes -= job->bytes;
        free(job->query);
    }
    if(job->result) {
        mysql_free_result(job->result);
    }
    free(job);
}

static void finishJob(Job *j, int outcome, int error) { // mutex held
    if(j->state == 0) {
        stats.queued--;
    } else if(j->state == 1) {
        stats.running--;
    }
    j->state = 2;
    j->completion.outcome = j->cancelled ? SQL_CANCELLED : outcome;
    j->completion.error = error;
    long long end = nowMs();
    j->completion.waitMs = (int)((j->started ? j->started : end) - j->enqueued);
    j->completion.executionMs = j->started ? (int)(end - j->started) : 0;
    if(j->completion.waitMs > stats.maxWaitMs) {
        stats.maxWaitMs = j->completion.waitMs;
    }
    if(j->completion.executionMs > stats.maxExecutionMs) {
        stats.maxExecutionMs = j->completion.executionMs;
    }
    if(j->query) {
        stats.queryBytes -= j->bytes;
        free(j->query);
        j->query = NULL;
    }
    if(j->completion.outcome == SQL_OK) {
        stats.succeeded++;
    } else if(j->completion.outcome == SQL_CANCELLED) {
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
    if(j->cancelled && j->result) {
        mysql_free_result(j->result);
        j->result = NULL;
    }
    if(j->forget) {
        unlinkJob(j);
    } else {
        stats.completed++;
    }
    pthread_cond_broadcast(&changed);
}

static bool eligible(Job *j) {
    if(j->state != 0) {
        return false;
    }
    if(!j->key[0]) {
        return true;
    }
    // Earlier accepted work with this key must finish before dispatch, even if
    // it has a lower priority. Completed jobs need not wait for GSC collection.
    for(Job *p = head; p != j; p = p->next) {
        if(p->state != 2 && !strcmp(p->key, j->key)) {
            return false;
        }
    }
    return true;
}

static Job *choose(int index) {
    long long now = nowMs();
    for(Job *p = head, *next; p; p = next) {
        next = p->next;
        if(p->state == 0 && now >= p->deadline) {
            finishJob(p, SQL_EXPIRED, 0);
        }
    }
    // Worker zero is reserved for progress. Other workers use weighted fair
    // service: progress dominates without starving reads or background uploads.
    static const int weights[] = {0, 0, 0, 0, 1, 0, 0, 2, 0, 3};
    int preferred = index == 0 ? 0 : weights[(schedule++) % 10];
    for(int pass = 0; pass < 2; pass++) {
        for(Job *p = head; p; p = p->next) {
            int lane = p->policy == SQL_WRITE ? 1 : p->policy;
            if(index == 0 && lane != 0) {
                continue;
            }
            if(pass == 0 && lane != preferred) {
                continue;
            }
            if(eligible(p)) {
                return p;
            }
        }
    }
    return NULL;
}

static MYSQL_RES *collect(MYSQL *db, bool save, int *error) {
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
    if((*error || !save) && first) {
        mysql_free_result(first);
        first = NULL;
    }
    return first;
}

static void *workerMain(void *arg) {
    int index = (int)(long)arg;
    Worker *w = &workers[index];
    bool threadReady = mysql_thread_init() == 0;
    if(threadReady) {
        w->db = connectWorker();
    }
    pthread_mutex_lock(&mutex);
    w->healthy = w->db != NULL;
    w->ready = true;
    pthread_cond_broadcast(&changed);
    while(starting && !stopping) {
        pthread_cond_wait(&changed, &mutex);
    }
    while(!stopping) {
        Job *j = choose(index);
        if(!j) {
            // Wake for admission/completion/cancellation, or to expire jobs whose
            // ordering dependency is still running on another connection.
            timespec deadline;
            clock_gettime(CLOCK_REALTIME, &deadline);
            deadline.tv_sec++;
            pthread_cond_timedwait(&changed, &mutex, &deadline);
            continue;
        }
        j->state = 1;
        j->started = nowMs();
        stats.queued--;
        stats.running++;
        pthread_mutex_unlock(&mutex);
        int error = 0;
        int outcome = SQL_OK;
        MYSQL_RES *result = NULL;
        if(!w->db || mysql_ping(w->db)) {
            if(w->db) {
                mysql_close(w->db);
            }
            w->db = connectWorker();
        }
        if(!w->db) {
            outcome = SQL_UNAVAILABLE;
        } else {
            bool read = j->policy == SQL_READ || j->policy == SQL_MENU;
            // Server-side SELECT deadline complements bounded socket I/O.
            const char *limit =
                read ? "SET SESSION max_execution_time=2000" : "SET SESSION max_execution_time=0";
            if(mysql_query(w->db, limit)) {
                error = mysql_errno(w->db);
                outcome = SQL_UNAVAILABLE;
            } else if(mysql_query(w->db, j->query)) {
                error = mysql_errno(w->db);
                outcome = lost(error) && !read ? SQL_UNKNOWN : SQL_ERROR;
            } else {
                result = collect(w->db, j->save, &error);
                if(error) {
                    outcome = lost(error) && !read ? SQL_UNKNOWN : SQL_ERROR;
                }
            }
            // A job cannot leak a transaction into the next independent job.
            // A transactional stored procedure must commit/rollback before returning.
            if(w->db->server_status & SERVER_STATUS_IN_TRANS) {
                mysql_query(w->db, "ROLLBACK");
                if(result) {
                    mysql_free_result(result);
                    result = NULL;
                }
                if(outcome == SQL_OK) {
                    outcome = SQL_INVALID;
                }
            }
            if(error && lost(error)) {
                mysql_close(w->db);
                w->db = NULL;
            }
        }
        pthread_mutex_lock(&mutex);
        j->result = result;
        finishJob(j, outcome, error);
    }
    pthread_mutex_unlock(&mutex);
    if(w->db) {
        mysql_close(w->db);
        w->db = NULL;
    }
    if(threadReady) {
        mysql_thread_end();
    }
    return NULL;
}

bool sqlPoolInit(const char *h, const char *u, const char *pw, const char *d, int p, int count) {
    pthread_mutex_lock(&mutex);
    if(initialized) {
        pthread_mutex_unlock(&mutex);
        return true;
    }
    if(count != MAX_WORKERS || starting) {
        pthread_mutex_unlock(&mutex);
        return false;
    }
    mysql_library_init(0, NULL, NULL);
    host = strdup(h);
    user = strdup(u);
    password = strdup(pw);
    database = strdup(d);
    port = p;
    starting = true;
    stopping = false;
    workerCount = count;
    bool ok = host && user && password && database;
    memset(workers, 0, sizeof(workers));
    for(int i = 0; ok && i < count; i++) {
        ok = pthread_create(&workers[i].thread, NULL, workerMain, (void *)(long)i) == 0;
        workers[i].created = ok;
    }
    bool ready = false;
    while(ok && !ready) {
        ready = true;
        for(int i = 0; i < count; i++) {
            if(!workers[i].ready) {
                ready = false;
            }
        }
        if(!ready) {
            pthread_cond_wait(&changed, &mutex);
        }
    }
    for(int i = 0; i < count; i++) {
        if(!workers[i].healthy) {
            ok = false;
        }
    }
    initialized = ok;
    starting = false;
    stopping = !ok;
    stats.workers = ok ? count : 0;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
    if(!ok) {
        sqlPoolShutdown();
    }
    return ok;
}

int sqlPoolSubmit(const char *query, bool save, int policy, const char *key, const char *scope,
                  int waitMs) {
    if(!query || !key || !scope || strlen(query) > MAX_QUERY || strlen(key) > MAX_KEY ||
       strlen(scope) > MAX_KEY || policy < 0 || policy > 4 || waitMs < 1 || waitMs > 60000) {
        return -SQL_INVALID;
    }
    pthread_mutex_lock(&mutex);
    int bytes = strlen(query) + 1;
    int error = 0;
    if(!initialized) {
        error = SQL_UNAVAILABLE;
    } else if(stats.outstanding >= MAX_JOBS || stats.queryBytes + bytes > MAX_BYTES ||
              (policy != SQL_PROGRESS &&
               (stats.outstanding >= NORMAL_JOBS || stats.queryBytes + bytes > NORMAL_BYTES)) ||
              (policy == SQL_MENU && menus >= MENU_JOBS)) {
        error = SQL_BUSY;
    }
    if(error) {
        stats.rejected++;
        pthread_mutex_unlock(&mutex);
        return -error;
    }
    Job *j = (Job *)calloc(1, sizeof(Job));
    if(j) {
        j->query = (char *)malloc(bytes);
    }
    if(!j || !j->query) {
        if(j) {
            free(j);
        }
        stats.rejected++;
        pthread_mutex_unlock(&mutex);
        return -SQL_BUSY;
    }
    do {
        nextId = nextId == INT_MAX ? 1 : nextId + 1;
        bool used = false;
        for(Job *p = head; p; p = p->next) {
            if(p->id == nextId) {
                used = true;
                break;
            }
        }
        if(!used) {
            break;
        }
    } while(true);
    j->id = nextId;
    j->policy = policy;
    j->save = save;
    j->bytes = bytes;
    strcpy(j->query, query);
    strcpy(j->key, key);
    strcpy(j->scope, scope);
    j->enqueued = nowMs();
    j->deadline = j->enqueued + waitMs;
    if(tail) {
        tail->next = j;
    } else {
        head = j;
    }
    tail = j;
    stats.accepted++;
    stats.outstanding++;
    stats.queued++;
    stats.queryBytes += bytes;
    if(policy == SQL_MENU) {
        menus++;
    }
    if(stats.outstanding > stats.peakJobs) {
        stats.peakJobs = stats.outstanding;
    }
    if(stats.queryBytes > stats.peakBytes) {
        stats.peakBytes = stats.queryBytes;
    }
    int id = j->id;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
    return id;
}

int sqlPoolDone(int *ids, int max) {
    pthread_mutex_lock(&mutex);
    int n = 0;
    for(Job *p = head; p && n < max; p = p->next) {
        if(p->state == 2) {
            ids[n++] = p->id;
        }
    }
    pthread_mutex_unlock(&mutex);
    return n;
}

bool sqlPoolStatus(int id, SqlCompletion *c) {
    pthread_mutex_lock(&mutex);
    bool found = false;
    for(Job *p = head; p; p = p->next) {
        if(p->id == id && p->state == 2) {
            *c = p->completion;
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&mutex);
    return found;
}

bool sqlPoolPeek(int id, MYSQL_RES **result, SqlCompletion *c) {
    pthread_mutex_lock(&mutex);
    bool found = false;
    for(Job *p = head; p; p = p->next) {
        if(p->id == id && p->state == 2) {
            *c = p->completion;
            *result = p->result;
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&mutex);
    return found;
}

bool sqlPoolTake(int id, MYSQL_RES **result, SqlCompletion *c) {
    pthread_mutex_lock(&mutex);
    bool found = false;
    for(Job *p = head; p; p = p->next) {
        if(p->id == id && p->state == 2) {
            *c = p->completion;
            *result = p->result;
            p->result = NULL;
            stats.completed--;
            unlinkJob(p);
            found = true;
            break;
        }
    }
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
    return found;
}

void sqlPoolCancel(const char *scope, bool prefix, bool forget) {
    pthread_mutex_lock(&mutex);
    for(Job *p = head, *next; p; p = next) {
        next = p->next;
        if(p->policy != SQL_MENU || !p->scope[0]) {
            continue;
        }
        bool match = prefix ? !strncmp(p->scope, scope, strlen(scope)) : !strcmp(p->scope, scope);
        if(!match) {
            continue;
        }
        p->cancelled = true;
        p->forget = forget;
        if(p->state == 0) {
            finishJob(p, SQL_CANCELLED, 0);
        } else if(p->state == 2) {
            if(p->result) {
                mysql_free_result(p->result);
                p->result = NULL;
            }
            if(p->completion.outcome != SQL_CANCELLED) {
                if(p->completion.outcome == SQL_OK) {
                    stats.succeeded--;
                } else {
                    stats.failed--;
                    if(p->completion.outcome == SQL_UNKNOWN) {
                        stats.unknown--;
                    }
                    if(p->completion.outcome == SQL_EXPIRED) {
                        stats.expired--;
                    }
                }
                stats.cancelled++;
            }
            p->completion.outcome = SQL_CANCELLED;
            if(forget) {
                stats.completed--;
                unlinkJob(p);
            }
        }
    }
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);
}

void sqlPoolNewMap() {
    sqlPoolCancel("", true, true);
}

SqlPoolStats sqlPoolStats() {
    pthread_mutex_lock(&mutex);
    SqlPoolStats s = stats;
    s.oldestWaitMs = 0;
    long long now = nowMs();
    for(Job *p = head; p; p = p->next) {
        if(p->state == 0 && now - p->enqueued > s.oldestWaitMs) {
            s.oldestWaitMs = (int)(now - p->enqueued);
        }
    }
    pthread_mutex_unlock(&mutex);
    return s;
}

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
    host = user = password = database = NULL;
    memset(workers, 0, sizeof(workers));
    memset(&stats, 0, sizeof(stats));
    workerCount = menus = 0;
    stopping = false;
    pthread_mutex_unlock(&mutex);
}
