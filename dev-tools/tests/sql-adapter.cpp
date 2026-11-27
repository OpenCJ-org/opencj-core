// Real MySQL integration tests for the production pool; disposable schema only.
#include "../../server-ext/mysql_async_pool.hpp"
#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <stdexcept>
#include <chrono>
#include <unistd.h>
#include <dirent.h>
using namespace std;
static int checks = 0;
static const int COMPLETION_TIMEOUT_MS = 15000;
static const int WORKER_START_TIMEOUT_MS = 1000;
static const int POLL_INTERVAL_US = 1000;

// Fixed admission contracts: derive neither the limits nor the expected worker count
// from the implementation being tested, or an accidental limit change would pass.
static const int WORKER_COUNT = 4;
static const int MENU_WORKER_COUNT = 3;
static const int MENU_CAPACITY = 64;
static const int NON_PROGRESS_CAPACITY = 384;
static const int NON_PROGRESS_QUERY_BYTES = 1536 * 1024;
static const int DEFAULT_REQUEST_DEADLINE_MS = 10000;
static const int PROGRESS_BURST_BUDGET_MS = 300;
static const int QUERY_FINISH_BUDGET_MS = 8000;
static const int LARGE_QUERY_PADDING_BYTES = 10000;
// Editor transactions are rolled back after this much silence.
static const int SESSION_IDLE_TIMEOUT_MS = 10000;
static const int SESSION_IDLE_MARGIN_MS = 1500;
static const int SLOW_READ_MS = 500;

static long long nowMs()
{
    return chrono::duration_cast<chrono::milliseconds>(
               chrono::steady_clock::now().time_since_epoch())
        .count();
}

static void check(bool value, const char *label)
{
    checks++;
    cout << "SQLPOOL CHECK " << value << ": " << label << endl;
    if(!value)
    {
        throw runtime_error(label);
    }
}

static int submitQuery(const string &query, int policy = SQL_READ, const string &key = "",
                       const string &scope = "", int deadlineMs = DEFAULT_REQUEST_DEADLINE_MS)
{
    return sqlPoolSubmit(query.c_str(), true, policy, key.c_str(), scope.c_str(), deadlineMs);
}

struct Reply
{
    SqlCompletion completion;
    vector<vector<string>> rows;
};

// Wait for the actual completion, copy its rows, and release the native result.
static Reply takeReply(int requestID)
{
    check(requestID > 0, "request admitted");
    long long deadlineMs = nowMs() + COMPLETION_TIMEOUT_MS;
    SqlCompletion completion;
    MYSQL_RES *result = NULL;
    while(!sqlPoolStatus(requestID, &completion) && nowMs() < deadlineMs)
    {
        usleep(POLL_INTERVAL_US);
    }
    if(!sqlPoolTake(requestID, &result, &completion))
    {
        throw runtime_error("completion deadline");
    }
    Reply reply;
    reply.completion = completion;
    if(result)
    {
        MYSQL_ROW row;
        while((row = mysql_fetch_row(result)))
        {
            vector<string> fields;
            for(unsigned i = 0; i < mysql_num_fields(result); i++)
            {
                fields.push_back(row[i] ? row[i] : "NULL");
            }
            reply.rows.push_back(fields);
        }
        mysql_free_result(result);
    }
    return reply;
}

static Reply runQuery(const string &query, int policy = SQL_READ, const string &key = "")
{
    return takeReply(submitQuery(query, policy, key));
}

static int queryScalar(const string &query)
{
    auto reply = runQuery(query);
    if(reply.completion.outcome != SQL_OK || reply.rows.empty() || reply.rows.front().empty())
    {
        throw runtime_error("scalar failed");
    }
    return stoi(reply.rows[0][0]);
}

static void drainReplies(const vector<int> &requestIDs)
{
    for(int requestID : requestIDs)
    {
        if(requestID > 0)
        {
            takeReply(requestID);
        }
    }
}

static void waitForRunningJobs(int count)
{
    long long deadlineMs = nowMs() + WORKER_START_TIMEOUT_MS;
    while(sqlPoolStats().running < count && nowMs() < deadlineMs)
    {
        usleep(POLL_INTERVAL_US);
    }
    check(sqlPoolStats().running >= count, "blocking fixture occupies intended workers");
}

// Count this process's threads so a growing queue cannot hide extra workers.
static int threadCount()
{
    DIR *directory = opendir("/proc/self/task");
    if(!directory)
    {
        throw runtime_error("thread inventory");
    }
    int count = 0;
    dirent *entry;
    while((entry = readdir(directory)))
    {
        if(entry->d_name[0] != '.')
        {
            count++;
        }
    }
    closedir(directory);
    return count;
}

static void verifyPerRunOrdering()
{
    // Priority cannot overtake earlier work for the same run.
    int first =
        submitQuery("INSERT INTO adapter_probe(value) SELECT 10 FROM (SELECT SLEEP(0.15)) a",
                    SQL_BACKGROUND, "run:order");
    int second =
        submitQuery("UPDATE adapter_probe SET value=11 WHERE value=10", SQL_PROGRESS, "run:order");
    takeReply(second);
    takeReply(first);
    check(queryScalar("SELECT COUNT(*) FROM adapter_probe WHERE value=11") == 1,
          "per-run order survives priority differences");
}

static void verifyMenuCapacity()
{
    vector<int> blockers;
    for(int i = 0; i < MENU_WORKER_COUNT; i++)
    {
        blockers.push_back(
            submitQuery("SELECT SLEEP(0.6),1", SQL_MENU, "", "block:" + to_string(i)));
    }
    waitForRunningJobs(MENU_WORKER_COUNT);
    // Exceed the 64-menu contract while three workers are occupied.
    vector<int> storm;
    for(int i = 0; i < 100; i++)
    {
        storm.push_back(submitQuery("SELECT SLEEP(0.02),1", SQL_MENU, "", "storm:" + to_string(i)));
    }
    auto saturation = sqlPoolStats();
    check(saturation.outstanding <= MENU_CAPACITY && saturation.rejected > 0,
          "menu admission is bounded at 64 outstanding jobs");
    long long startedAtMs = nowMs();
    auto progress =
        runQuery("INSERT INTO adapter_probe(value) VALUES(20)", SQL_PROGRESS, "run:priority");
    long long latencyMs = nowMs() - startedAtMs;
    check(progress.completion.outcome == SQL_OK && latencyMs < PROGRESS_BURST_BUDGET_MS,
          "progress completes while all three menu workers are busy");
    cout << "SQLPOOL METRIC progress_during_menu_burst_ms=" << latencyMs << endl;
    sqlPoolCancel("storm:", SqlScopeMatch::Prefix, SqlCompletionHandling::Retain);
    for(int requestID : storm)
    {
        if(requestID > 0)
        {
            check(takeReply(requestID).completion.outcome == SQL_CANCELLED,
                  "queued obsolete menu returns cancellation");
        }
    }
    drainReplies(blockers);
    check(sqlPoolStats().outstanding == 0, "all results collected after storm");
}

static void verifyCompletionCapacity()
{
    // Completed jobs occupy slots too. No consumer means bounded admission.
    // Submit beyond the 384 non-progress slots, without consuming results.
    vector<int> buffered;
    for(int i = 0; i < 700; i++)
    {
        int requestID = submitQuery("SELECT 1", SQL_READ);
        if(requestID > 0)
        {
            buffered.push_back(requestID);
        }
    }
    check(sqlPoolStats().outstanding <= NON_PROGRESS_CAPACITY &&
              buffered.size() <= NON_PROGRESS_CAPACITY,
          "uncollected results count against non-progress capacity");
    check(runQuery("INSERT INTO adapter_probe(value) VALUES(21)", SQL_PROGRESS, "run:reserved")
                  .completion.outcome == SQL_OK,
          "reserved progress capacity survives a stalled consumer");
    drainReplies(buffered);
}

static void verifyQueryByteCapacity()
{
    // Query bytes are a second independent admission bound.
    string largeQuery = "DO SLEEP(0.02) /*" + string(LARGE_QUERY_PADDING_BYTES, 'x') + "*/";
    vector<int> largeJobs;
    for(int i = 0; i < 400; i++)
    {
        int requestID = submitQuery(largeQuery, SQL_BACKGROUND, "bulk");
        if(requestID > 0)
        {
            largeJobs.push_back(requestID);
        }
    }
    auto saturatedPool = sqlPoolStats();
    check(saturatedPool.queryBytes <= NON_PROGRESS_QUERY_BYTES &&
              largeJobs.size() < NON_PROGRESS_CAPACITY,
          "byte limit rejects before job-count limit");
    check(runQuery("INSERT INTO adapter_probe(value) VALUES(22)", SQL_PROGRESS, "run:bytes")
                  .completion.outcome == SQL_OK,
          "progress byte reserve remains available");
    drainReplies(largeJobs);
}

static void verifyQueuedExpiry()
{
    int slow = submitQuery("DO SLEEP(0.2)", SQL_PROGRESS, "run:expire");
    int expired = submitQuery("INSERT INTO adapter_probe(value) VALUES(99)", SQL_PROGRESS,
                              "run:expire", "", 20);
    takeReply(slow);
    check(takeReply(expired).completion.outcome == SQL_EXPIRED &&
              queryScalar("SELECT COUNT(*) FROM adapter_probe WHERE value=99") == 0,
          "expired queued write is rejected without execution");
}

static void verifyMapCancellation()
{
    int persistence =
        submitQuery("INSERT INTO adapter_probe(value) SELECT 30 FROM (SELECT SLEEP(0.2)) a",
                    SQL_PROGRESS, "run:map");
    int oldMenu = submitQuery("SELECT SLEEP(0.4),1", SQL_MENU, "", "p:1:board");
    check(oldMenu > 0, "map-scoped menu request admitted");
    sqlPoolNewMap();
    check(takeReply(persistence).completion.outcome == SQL_OK,
          "accepted write survives map lifecycle cancellation");
    // The old menu query sleeps 400 ms; leave time for its worker to discard the reply.
    usleep(450000);
    SqlCompletion unused;
    check(!sqlPoolStatus(oldMenu, &unused), "old-map menu result discarded");
    check(sqlPoolStats().outstanding == 0 && sqlPoolStats().workers == WORKER_COUNT,
          "map transition retains workers without leaking completed tasks");
}

static Reply runSessionQuery(int sessionId, const string &query)
{
    return takeReply(sqlPoolSubmitSession(sessionId, query.c_str(), true));
}

static int countProbeValue(int value)
{
    return queryScalar("SELECT COUNT(*) FROM adapter_probe WHERE value=" + to_string(value));
}

// An abandoned transaction closes once its worker has rolled it back; wait for that.
static int beginSessionWhenFree()
{
    long long deadlineMs = nowMs() + COMPLETION_TIMEOUT_MS;
    int sessionId = sqlPoolBeginSession();
    while(sessionId == -SQL_BUSY && nowMs() < deadlineMs)
    {
        usleep(POLL_INTERVAL_US);
        sessionId = sqlPoolBeginSession();
    }
    return sessionId;
}

static void verifySessionCommit()
{
    int sessionId = sqlPoolBeginSession();
    check(sessionId > 0, "editor transaction opens");
    check(sqlPoolBeginSession() == -SQL_BUSY, "a second editor transaction is refused");

    // Submitted together: the second statement must run on the same connection.
    int insert = sqlPoolSubmitSession(sessionId, "INSERT INTO adapter_probe(value) VALUES(60)",
                                      false);
    int lastId = sqlPoolSubmitSession(sessionId, "SELECT LAST_INSERT_ID()", true);
    check(takeReply(insert).completion.outcome == SQL_OK, "transaction statement succeeds");
    Reply lastIdReply = takeReply(lastId);
    check(lastIdReply.completion.outcome == SQL_OK && lastIdReply.rows.size() == 1,
          "pipelined statement returns its row");
    string insertedSeq = lastIdReply.rows[0][0];
    check(queryScalar("SELECT COUNT(*) FROM adapter_probe WHERE seq=" + insertedSeq) == 0,
          "uncommitted row is invisible to other connections");
    Reply ownRead =
        runSessionQuery(sessionId, "SELECT COUNT(*) FROM adapter_probe WHERE seq=" + insertedSeq);
    check(ownRead.completion.outcome == SQL_OK && ownRead.rows[0][0] == "1",
          "pipelined statements share one connection and transaction");

    // With the transaction bound, the slow reads fill the two other read workers and
    // one waits; progress still runs at once on its reserved worker.
    vector<int> slowReads;
    for(int readIndex = 0; readIndex < MENU_WORKER_COUNT; readIndex++)
    {
        slowReads.push_back(submitQuery("SELECT SLEEP(" + to_string(SLOW_READ_MS / 1000.0) +
                                        ")"));
    }
    long long progressStartMs = nowMs();
    Reply progress = runQuery("INSERT INTO adapter_probe(value) VALUES(61)", SQL_PROGRESS,
                              "run:session");
    long long progressLatencyMs = nowMs() - progressStartMs;
    check(progress.completion.outcome == SQL_OK && progressLatencyMs < SLOW_READ_MS,
          "an open transaction never takes the progress worker");
    drainReplies(slowReads);

    check(takeReply(sqlPoolEndSession(sessionId, true)).completion.outcome == SQL_OK,
          "COMMIT succeeds");
    check(countProbeValue(60) == 1, "committed row becomes visible");
    check(sqlPoolSubmitSession(sessionId, "SELECT 1", true) == -SQL_EXPIRED,
          "an ended transaction accepts no statements");
}

static void verifySessionRollback()
{
    int sessionId = beginSessionWhenFree();
    check(sessionId > 0, "transaction opens after the previous one ended");
    Reply insert = runSessionQuery(sessionId, "INSERT INTO adapter_probe(value) VALUES(70)");
    check(insert.completion.outcome == SQL_OK, "statement before rollback succeeds");
    check(takeReply(sqlPoolEndSession(sessionId, false)).completion.outcome == SQL_OK,
          "ROLLBACK succeeds");
    check(countProbeValue(70) == 0, "rolled-back row is never visible");
}

static void verifySessionFailure()
{
    int sessionId = beginSessionWhenFree();
    check(sessionId > 0, "transaction opens for the failure case");
    int insert = sqlPoolSubmitSession(sessionId, "INSERT INTO adapter_probe(value) VALUES(80)",
                                      false);
    int failing = sqlPoolSubmitSession(sessionId, "SELECT * FROM missing_adapter_table", true);
    int later = sqlPoolSubmitSession(sessionId, "INSERT INTO adapter_probe(value) VALUES(81)",
                                     false);
    int commit = sqlPoolEndSession(sessionId, true);
    check(takeReply(insert).completion.outcome == SQL_OK, "statement before the failure runs");
    check(takeReply(failing).completion.outcome == SQL_ERROR, "failing statement is explicit");
    check(takeReply(later).completion.outcome == SQL_ERROR,
          "statements after a failure do not run");
    check(takeReply(commit).completion.outcome == SQL_ERROR,
          "COMMIT after a failure reports the rollback");
    check(countProbeValue(80) == 0 && countProbeValue(81) == 0,
          "a failed transaction leaves no rows");
}

static void verifySessionConnectionLoss()
{
    int sessionId = beginSessionWhenFree();
    check(sessionId > 0, "transaction opens for the connection-loss case");
    runSessionQuery(sessionId, "INSERT INTO adapter_probe(value) VALUES(85)");
    // Killing its own connection discards the transaction; a reconnect must not
    // let later statements run outside it.
    check(runSessionQuery(sessionId, "KILL CONNECTION_ID()").completion.outcome != SQL_OK,
          "killed transaction connection is reported");
    Reply later = runSessionQuery(sessionId, "INSERT INTO adapter_probe(value) VALUES(86)");
    check(later.completion.outcome == SQL_ERROR,
          "no statement runs after the transaction connection was lost");
    check(takeReply(sqlPoolEndSession(sessionId, true)).completion.outcome == SQL_ERROR,
          "COMMIT after connection loss is not reported as success");
    check(countProbeValue(85) == 0 && countProbeValue(86) == 0,
          "connection loss leaves no partial transaction");

    int nextSessionId = beginSessionWhenFree();
    check(nextSessionId > 0, "transaction opens after connection loss");
    check(runSessionQuery(nextSessionId, "SELECT 1").completion.outcome == SQL_OK,
          "the next transaction reconnects");
    takeReply(sqlPoolEndSession(nextSessionId, false));
}

static void verifySessionIdleTimeout()
{
    int sessionId = beginSessionWhenFree();
    check(sessionId > 0, "transaction opens for the idle case");
    runSessionQuery(sessionId, "INSERT INTO adapter_probe(value) VALUES(90)");
    usleep((SESSION_IDLE_TIMEOUT_MS + SESSION_IDLE_MARGIN_MS) * 1000);
    check(sqlPoolSubmitSession(sessionId, "SELECT 1", true) == -SQL_EXPIRED,
          "an idle transaction is closed");
    int nextSessionId = beginSessionWhenFree();
    check(nextSessionId > 0, "an idle transaction frees its worker");
    takeReply(sqlPoolEndSession(nextSessionId, false));
    check(countProbeValue(90) == 0, "an idle transaction is rolled back");
}

static void verifySessionMapChange()
{
    int sessionId = beginSessionWhenFree();
    check(sessionId > 0, "transaction opens before the map change");
    runSessionQuery(sessionId, "INSERT INTO adapter_probe(value) VALUES(95)");
    sqlPoolNewMap();
    check(sqlPoolEndSession(sessionId, true) == -SQL_EXPIRED,
          "the old map's transaction cannot commit");
    int nextSessionId = beginSessionWhenFree();
    check(nextSessionId > 0, "the new map can open a transaction");
    takeReply(sqlPoolEndSession(nextSessionId, false));
    check(countProbeValue(95) == 0, "a map change rolls back the open transaction");

    // A COMMIT requested before the map change still settles.
    int committingSessionId = beginSessionWhenFree();
    check(committingSessionId > 0, "transaction opens before a requested COMMIT");
    int insert = sqlPoolSubmitSession(committingSessionId,
                                      "INSERT INTO adapter_probe(value) "
                                      "SELECT 96 FROM (SELECT SLEEP(0.2)) delay",
                                      false);
    int commit = sqlPoolEndSession(committingSessionId, true);
    sqlPoolNewMap();
    check(takeReply(insert).completion.outcome == SQL_OK, "queued statement survives the map");
    check(takeReply(commit).completion.outcome == SQL_OK && countProbeValue(96) == 1,
          "a requested COMMIT survives the map change");
}

// Exact cancellation is for owned reads, without putting them in the menu quota.
static void verifyOwnedReadCancellation()
{
    int active = submitQuery("SELECT SLEEP(0.15)", SQL_READ, "owned-read");
    waitForRunningJobs(1);
    int queued = submitQuery("SELECT 42", SQL_READ, "owned-read");
    check(sqlPoolCancelRead(queued, SqlCompletionHandling::Retain),
          "owned queued read accepts cancellation");
    check(takeReply(queued).completion.outcome == SQL_CANCELLED,
          "owned queued read returns cancelled instead of executing");
    check(sqlPoolCancelRead(active, SqlCompletionHandling::Retain),
          "owned running read accepts cancellation");
    Reply cancelled = takeReply(active);
    check(cancelled.completion.outcome == SQL_CANCELLED && cancelled.rows.empty(),
          "running read drops its result after its worker finishes");

    int completed = submitQuery("SELECT 43");
    long long deadlineMs = nowMs() + COMPLETION_TIMEOUT_MS;
    SqlCompletion completion;
    while(!sqlPoolStatus(completed, &completion) && nowMs() < deadlineMs)
    {
        usleep(POLL_INTERVAL_US);
    }
    check(sqlPoolStatus(completed, &completion), "owned completed read is ready");
    check(sqlPoolCancelRead(completed, SqlCompletionHandling::Discard),
          "owned completed read releases its result");
    check(!sqlPoolStatus(completed, &completion), "discarded read leaves no completion");

    int write = submitQuery("INSERT INTO adapter_probe(value) VALUES(987654)", SQL_WRITE);
    check(!sqlPoolCancelRead(write, SqlCompletionHandling::Discard),
          "read cancellation refuses accepted writes");
    check(takeReply(write).completion.outcome == SQL_OK,
          "refused cancellation leaves write intact");
    check(queryScalar("SELECT COUNT(*) FROM adapter_probe WHERE value=987654") == 1,
          "accepted write still executes once");
    check(!sqlPoolCancelRead(-1, SqlCompletionHandling::Discard),
          "unknown read cancellation is harmless");
}

static void verifyDisconnectCancellation()
{
    int disconnected = submitQuery("SELECT SLEEP(0.2),1", SQL_MENU, "", "p:8:board");
    check(disconnected > 0, "disconnect-scoped menu request admitted");
    sqlPoolCancel("p:8:", SqlScopeMatch::Prefix, SqlCompletionHandling::Discard);
    // This query sleeps 200 ms; observe disposal after the worker has settled.
    usleep(250000);
    check(sqlPoolStats().outstanding == 0, "disconnect cancels scoped reads without leaking jobs");
}

static void verifyFairScheduling()
{
    vector<int> writes;
    for(int i = 0; i < 100; i++)
    {
        writes.push_back(submitQuery("DO SLEEP(0.01)", SQL_PROGRESS, "r:" + to_string(i)));
    }
    int background =
        submitQuery("INSERT INTO adapter_probe(value) VALUES(40)", SQL_BACKGROUND, "background");
    auto fair = takeReply(background);
    check(fair.completion.outcome == SQL_OK && fair.completion.waitMs < 1000,
          "background work is not starved by continuous progress work");
    drainReplies(writes);
}

static void verifyReadDeadline()
{
    auto timed = runQuery("SELECT SLEEP(10),1", SQL_READ);
    cout << "SQLPOOL METRIC slow_outcome=" << timed.completion.outcome
         << " error=" << timed.completion.error << " execution_ms=" << timed.completion.executionMs
         << endl;
    check(timed.completion.executionMs < QUERY_FINISH_BUDGET_MS &&
              (timed.completion.outcome != SQL_OK ||
               (!timed.rows.empty() && timed.rows[0][0] == "1")),
          "slow read is interrupted within the configured budget");
    check(queryScalar("SELECT 1") == 1, "pool recovers after slow read");
}

static void verifyUncertainWrites()
{
    // A long writing CALL may have committed before losing its reply.
    runQuery("CREATE PROCEDURE adapter_uncertain() BEGIN INSERT INTO adapter_probe(value) "
             "VALUES(50); DO SLEEP(10); END",
             SQL_PROGRESS);
    auto uncertain = runQuery("CALL adapter_uncertain()", SQL_PROGRESS, "run:uncertain");
    check(uncertain.completion.outcome == SQL_UNKNOWN &&
              uncertain.completion.executionMs < QUERY_FINISH_BUDGET_MS,
          "lost write reply is explicitly uncertain");
    check(queryScalar("SELECT COUNT(*) FROM adapter_probe WHERE value=50") <= 1,
          "uncertain write is never automatically replayed");
}

int main(int argc, char **argv)
{
    try
    {
        if(argc != 2)
        {
            throw runtime_error("config path required");
        }
        ifstream config(argv[1]);
        string host;
        string user;
        string password;
        string database;
        string port;
        getline(config, host);
        getline(config, user);
        getline(config, password);
        getline(config, database);
        getline(config, port);
        if(database.find("opencj_verify_192_") != 0)
        {
            throw runtime_error("unsafe test schema");
        }
        check(sqlPoolInit(host.c_str(), user.c_str(), password.c_str(), database.c_str(),
                          stoi(port), WORKER_COUNT),
              "four permanent workers connected");
        check(sqlPoolStats().workers == WORKER_COUNT, "pool size remains four");
        int initialThreadCount = threadCount();
        check(initialThreadCount == WORKER_COUNT + 1, "exactly four native worker threads");
        runQuery("CREATE TABLE adapter_probe(seq INT AUTO_INCREMENT PRIMARY KEY,value INT) "
                 "ENGINE=InnoDB",
                 SQL_PROGRESS);
        check(runQuery("SELECT value FROM adapter_probe").rows.empty(), "empty read is successful");
        check(runQuery("SELECT * FROM missing_adapter_table").completion.outcome == SQL_ERROR,
              "SQL error remains explicit");
        verifyPerRunOrdering();

        verifyMenuCapacity();

        verifyCompletionCapacity();

        verifyQueryByteCapacity();

        verifyQueuedExpiry();

        verifyMapCancellation();

        verifySessionCommit();

        verifySessionRollback();

        verifySessionFailure();

        verifySessionConnectionLoss();

        verifySessionIdleTimeout();

        verifySessionMapChange();

        verifyDisconnectCancellation();

        verifyOwnedReadCancellation();

        verifyFairScheduling();

        verifyReadDeadline();

        verifyUncertainWrites();

        auto finalStats = sqlPoolStats();
        check(finalStats.outstanding == 0 && finalStats.queryBytes == 0,
              "all query allocations and completions released");
        cout << "SQLPOOL METRIC accepted=" << finalStats.accepted
             << " rejected=" << finalStats.rejected << " peak_jobs=" << finalStats.peakJobs
             << " peak_query_bytes=" << finalStats.peakBytes
             << " max_wait_ms=" << finalStats.maxWaitMs
             << " max_execution_ms=" << finalStats.maxExecutionMs << endl;
        check(threadCount() == initialThreadCount,
              "query volume does not create additional worker threads");
        sqlPoolShutdown();
        cout << "SQLPOOL COMPLETE checks=" << checks << endl;
        return 0;
    }
    catch(const exception &error)
    {
        cout << "SQLPOOL FAILURE " << error.what() << endl;
        sqlPoolShutdown();
        return 1;
    }
}
