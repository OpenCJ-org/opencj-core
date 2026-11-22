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

bool sqlPoolInit(const char *, const char *, const char *, const char *, int, int);
int sqlPoolSubmit(const char *, bool, int, const char *, const char *, int);
int sqlPoolDone(int *, int);
bool sqlPoolStatus(int, SqlCompletion *);
bool sqlPoolTake(int, MYSQL_RES **, SqlCompletion *);
// Main-thread consumers may inspect completed native payloads before taking ownership.
bool sqlPoolPeek(int, MYSQL_RES **, SqlCompletion *);
void sqlPoolCancel(const char *, bool, bool);
void sqlPoolNewMap();
SqlPoolStats sqlPoolStats();
void sqlPoolShutdown(); // Test/process shutdown only; never on map transitions.
#endif
