#ifndef OPENCJ_MYSQL_ASYNC_POOL_HPP
#define OPENCJ_MYSQL_ASYNC_POOL_HPP
#include <mysql/mysql.h>

// Policies describe semantics, never inferred from SQL text.
enum SqlPolicy {
    SQL_PROGRESS = 0,
    SQL_READ = 1,
    SQL_BACKGROUND = 2,
    SQL_MENU = 3,
    SQL_WRITE = 4
};

enum SqlOutcome {
    SQL_OK = 0,
    SQL_ERROR = 1,
    SQL_UNAVAILABLE = 2,
    SQL_UNKNOWN = 3,
    SQL_EXPIRED = 4,
    SQL_CANCELLED = 5,
    SQL_BUSY = 6,
    SQL_INVALID = 7
};

struct SqlCompletion {
    int outcome;
    int error;
    int waitMs;
    int executionMs;
};

struct SqlPoolStats {
    int workers;
    int queued;
    int running;
    int completed;
    int outstanding;
    int queryBytes;
    int peakJobs;
    int peakBytes;
    int accepted;
    int succeeded;
    int failed;
    int cancelled;
    int rejected;
    int expired;
    int unknown;
    int oldestWaitMs;
    int maxWaitMs;
    int maxExecutionMs;
};

enum class SqlScopeMatch {
    Exact,
    Prefix
};

enum class SqlCompletionHandling {
    Retain,
    Discard
};

// Call lifecycle operations from the main thread. Initialization requires four
// workers and keeps an existing initialized pool, including its credentials.
bool sqlPoolInit(const char *host, const char *user, const char *password, const char *database,
                 int port, int workerCount);

// Copy query/key/scope on admission. Return a positive job ID or -SqlOutcome.
// The wait limit applies before execution. Equal nonempty keys execute in order.
int sqlPoolSubmit(const char *query, bool retainResult, int policy, const char *orderingKey,
                  const char *scope, int waitMs);

// Copy at most capacity completed IDs into caller-owned storage; do not consume them.
int sqlPoolDone(int *completedIds, int capacity);

// Outputs are written only when a completed job is found. Callers provide valid
// output pointers; false means the job is absent or has not completed.
bool sqlPoolStatus(int jobId, SqlCompletion *completion);

// Take consumes the completion and transfers the result, if any, to the caller.
// The caller must release it with mysql_free_result.
bool sqlPoolTake(int jobId, MYSQL_RES **result, SqlCompletion *completion);

// Peek borrows a result for main-thread inspection. It remains pool-owned until
// take; cancellation, consumption or shutdown can release it.
bool sqlPoolPeek(int jobId, MYSQL_RES **result, SqlCompletion *completion);

// A native owner may cancel its exact read without changing its scheduling policy.
// Active work keeps its connection until the worker finishes. Writes are rejected.
bool sqlPoolCancelRead(int id, SqlCompletionHandling completionHandling);

// Only scoped menu reads are cancelled. Retain exposes a cancelled completion;
// Discard releases it once its worker stops. Accepted writes are not cancelled.
void sqlPoolCancel(const char *scope, SqlScopeMatch scopeMatch,
                   SqlCompletionHandling completionHandling);
// A map change abandons an editor transaction that has not requested COMMIT
// (its bound worker rolls it back); a queued COMMIT still settles.
void sqlPoolNewMap();
SqlPoolStats sqlPoolStats();

// Editor transactions. At most one is open. Its statements run in submission order
// on one connection inside a single transaction; from its first statement until
// COMMIT or ROLLBACK it binds one non-progress worker, which then serves only it.
// An idle (10 s) or overlong (120 s) transaction is rolled back automatically.

// Return a positive session ID, -SQL_BUSY while another transaction is open, or
// -SQL_UNAVAILABLE without an initialized pool. No SQL runs until a statement.
int sqlPoolBeginSession();

// Queue one statement. Return a job ID with the usual completion contract, or
// -SQL_EXPIRED when the session is not open (ended, timed out or abandoned).
// A statement that fails or expires unrun fails the transaction: later statements
// complete with SQL_ERROR without running, and a requested COMMIT rolls back.
int sqlPoolSubmitSession(int sessionId, const char *query, bool retainResult);

// Queue COMMIT (commit=true) or ROLLBACK and close the session after it. COMMIT's
// completion is SQL_OK, SQL_UNKNOWN (reply lost; it may have committed) or
// SQL_ERROR (rolled back, including after an earlier failure). Same errors as submit.
int sqlPoolEndSession(int sessionId, bool commit);

// Test/process shutdown only; never on map transitions.
void sqlPoolShutdown();
#endif
