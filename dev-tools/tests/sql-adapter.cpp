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

static long long nowMs() {
    return chrono::duration_cast<chrono::milliseconds>(
               chrono::steady_clock::now().time_since_epoch())
        .count();
}

static void check(bool value, const char *label) {
    checks++;
    cout << "SQLPOOL CHECK " << value << ": " << label << endl;
    if(!value) {
        throw runtime_error(label);
    }
}

static int submitQuery(const string &query, int policy = SQL_READ, const string &key = "",
                       const string &scope = "", int deadlineMs = 10000) {
    return sqlPoolSubmit(query.c_str(), true, policy, key.c_str(), scope.c_str(), deadlineMs);
}

struct Reply {
    SqlCompletion completion;
    vector<vector<string>> rows;
};

// Wait for the actual completion, copy its rows, and release the native result.
static Reply takeReply(int id) {
    check(id > 0, "request admitted");
    long long deadlineMs = nowMs() + COMPLETION_TIMEOUT_MS;
    SqlCompletion completion;
    MYSQL_RES *result = NULL;
    while(!sqlPoolStatus(id, &completion) && nowMs() < deadlineMs) {
        usleep(POLL_INTERVAL_US);
    }
    if(!sqlPoolTake(id, &result, &completion)) {
        throw runtime_error("completion deadline");
    }
    Reply reply;
    reply.completion = completion;
    if(result) {
        MYSQL_ROW row;
        while((row = mysql_fetch_row(result))) {
            vector<string> fields;
            for(unsigned i = 0; i < mysql_num_fields(result); i++) {
                fields.push_back(row[i] ? row[i] : "NULL");
            }
            reply.rows.push_back(fields);
        }
        mysql_free_result(result);
    }
    return reply;
}

static Reply runQuery(const string &query, int policy = SQL_READ, const string &key = "") {
    return takeReply(submitQuery(query, policy, key));
}

static int queryScalar(const string &query) {
    auto reply = runQuery(query);
    if(reply.completion.outcome != SQL_OK || reply.rows.empty()) {
        throw runtime_error("scalar failed");
    }
    return stoi(reply.rows[0][0]);
}

static void drainReplies(const vector<int> &ids) {
    for(int id : ids) {
        if(id > 0) {
            takeReply(id);
        }
    }
}

static void waitForRunningJobs(int count) {
    long long deadlineMs = nowMs() + WORKER_START_TIMEOUT_MS;
    while(sqlPoolStats().running < count && nowMs() < deadlineMs) {
        usleep(POLL_INTERVAL_US);
    }
    check(sqlPoolStats().running >= count, "blocking fixture occupies intended workers");
}

// Count this process's threads so a growing queue cannot hide extra workers.
static int threadCount() {
    DIR *directory = opendir("/proc/self/task");
    if(!directory) {
        throw runtime_error("thread inventory");
    }
    int count = 0;
    dirent *entry;
    while((entry = readdir(directory))) {
        if(entry->d_name[0] != '.') {
            count++;
        }
    }
    closedir(directory);
    return count;
}

static void verifyPerRunOrdering() {
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

static void verifyMenuCapacity() {
    vector<int> blockers;
    for(int i = 0; i < 3; i++) {
        blockers.push_back(
            submitQuery("SELECT SLEEP(0.6),1", SQL_MENU, "", "block:" + to_string(i)));
    }
    waitForRunningJobs(3);
    // Exceed the 64-menu contract while three workers are occupied.
    vector<int> storm;
    for(int i = 0; i < 100; i++) {
        storm.push_back(submitQuery("SELECT SLEEP(0.02),1", SQL_MENU, "", "storm:" + to_string(i)));
    }
    auto saturation = sqlPoolStats();
    check(saturation.outstanding <= 64 && saturation.rejected > 0,
          "menu admission is bounded at 64 outstanding jobs");
    long long begin = nowMs();
    auto progress =
        runQuery("INSERT INTO adapter_probe(value) VALUES(20)", SQL_PROGRESS, "run:priority");
    long long latency = nowMs() - begin;
    check(progress.completion.outcome == SQL_OK && latency < 300,
          "progress completes while all three menu workers are busy");
    cout << "SQLPOOL METRIC progress_during_menu_burst_ms=" << latency << endl;
    sqlPoolCancel("storm:", SqlScopeMatch::Prefix, SqlCompletionHandling::Retain);
    for(int id : storm) {
        if(id > 0) {
            check(takeReply(id).completion.outcome == SQL_CANCELLED,
                  "queued obsolete menu returns cancellation");
        }
    }
    drainReplies(blockers);
    check(sqlPoolStats().outstanding == 0, "all results collected after storm");
}

static void verifyCompletionCapacity() {
    // Completed jobs occupy slots too. No consumer means bounded admission.
    // Submit beyond the 384 non-progress slots, without consuming results.
    vector<int> buffered;
    for(int i = 0; i < 700; i++) {
        int id = submitQuery("SELECT 1", SQL_READ);
        if(id > 0) {
            buffered.push_back(id);
        }
    }
    check(sqlPoolStats().outstanding <= 384 && buffered.size() <= 384,
          "uncollected results count against non-progress capacity");
    check(runQuery("INSERT INTO adapter_probe(value) VALUES(21)", SQL_PROGRESS, "run:reserved")
                  .completion.outcome == SQL_OK,
          "reserved progress capacity survives a stalled consumer");
    drainReplies(buffered);
}

static void verifyQueryByteCapacity() {
    // Query bytes are a second independent admission bound.
    string large = "DO SLEEP(0.02) /*" + string(10000, 'x') + "*/";
    vector<int> largeJobs;
    for(int i = 0; i < 400; i++) {
        int id = submitQuery(large, SQL_BACKGROUND, "bulk");
        if(id > 0) {
            largeJobs.push_back(id);
        }
    }
    auto bytes = sqlPoolStats();
    check(bytes.queryBytes <= 1536 * 1024 && largeJobs.size() < 384,
          "byte limit rejects before job-count limit");
    check(runQuery("INSERT INTO adapter_probe(value) VALUES(22)", SQL_PROGRESS, "run:bytes")
                  .completion.outcome == SQL_OK,
          "progress byte reserve remains available");
    drainReplies(largeJobs);
}

static void verifyQueuedExpiry() {
    int slow = submitQuery("DO SLEEP(0.2)", SQL_PROGRESS, "run:expire");
    int expired = submitQuery("INSERT INTO adapter_probe(value) VALUES(99)", SQL_PROGRESS,
                              "run:expire", "", 20);
    takeReply(slow);
    check(takeReply(expired).completion.outcome == SQL_EXPIRED &&
              queryScalar("SELECT COUNT(*) FROM adapter_probe WHERE value=99") == 0,
          "expired queued write is rejected without execution");
}

static void verifyMapCancellation() {
    int persistence =
        submitQuery("INSERT INTO adapter_probe(value) SELECT 30 FROM (SELECT SLEEP(0.2)) a",
                    SQL_PROGRESS, "run:map");
    int oldMenu = submitQuery("SELECT SLEEP(0.4),1", SQL_MENU, "", "p:1:board");
    sqlPoolNewMap();
    check(takeReply(persistence).completion.outcome == SQL_OK,
          "accepted write survives map lifecycle cancellation");
    usleep(450000);
    SqlCompletion unused;
    check(!sqlPoolStatus(oldMenu, &unused), "old-map menu result discarded");
    check(sqlPoolStats().outstanding == 0 && sqlPoolStats().workers == 4,
          "map transition retains workers without leaking completed tasks");
}

static void verifyDisconnectCancellation() {
    int disconnected = submitQuery("SELECT SLEEP(0.2),1", SQL_MENU, "", "p:8:board");
    sqlPoolCancel("p:8:", SqlScopeMatch::Prefix, SqlCompletionHandling::Discard);
    usleep(250000);
    check(sqlPoolStats().outstanding == 0, "disconnect cancels scoped reads without leaking jobs");
}

static void verifyFairScheduling() {
    vector<int> writes;
    for(int i = 0; i < 100; i++) {
        writes.push_back(submitQuery("DO SLEEP(0.01)", SQL_PROGRESS, "r:" + to_string(i)));
    }
    int background =
        submitQuery("INSERT INTO adapter_probe(value) VALUES(40)", SQL_BACKGROUND, "background");
    auto fair = takeReply(background);
    check(fair.completion.outcome == SQL_OK && fair.completion.waitMs < 1000,
          "background work is not starved by continuous progress work");
    drainReplies(writes);
}

static void verifyReadDeadline() {
    auto timed = runQuery("SELECT SLEEP(10),1", SQL_READ);
    cout << "SQLPOOL METRIC slow_outcome=" << timed.completion.outcome
         << " error=" << timed.completion.error << " execution_ms=" << timed.completion.executionMs
         << endl;
    check(timed.completion.executionMs < 8000 && (timed.completion.outcome != SQL_OK ||
                                                  (!timed.rows.empty() && timed.rows[0][0] == "1")),
          "slow read is interrupted within the configured budget");
    check(queryScalar("SELECT 1") == 1, "pool recovers after slow read");
}

static void verifyUncertainWrites() {
    // A long writing CALL may have committed before losing its reply.
    runQuery("CREATE PROCEDURE adapter_uncertain() BEGIN INSERT INTO adapter_probe(value) "
             "VALUES(50); DO SLEEP(10); END",
             SQL_PROGRESS);
    auto uncertain = runQuery("CALL adapter_uncertain()", SQL_PROGRESS, "run:uncertain");
    check(uncertain.completion.outcome == SQL_UNKNOWN && uncertain.completion.executionMs < 8000,
          "lost write reply is explicitly uncertain");
    check(queryScalar("SELECT COUNT(*) FROM adapter_probe WHERE value=50") <= 1,
          "uncertain write is never automatically replayed");
}

int main(int argc, char **argv) {
    try {
        if(argc != 2) {
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
        if(database.find("opencj_verify_192_") != 0) {
            throw runtime_error("unsafe test schema");
        }
        check(sqlPoolInit(host.c_str(), user.c_str(), password.c_str(), database.c_str(),
                          stoi(port), 4),
              "four permanent workers connected");
        check(sqlPoolStats().workers == 4, "pool size remains four");
        int threads = threadCount();
        check(threads == 5, "exactly four native worker threads");
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

        verifyDisconnectCancellation();

        verifyFairScheduling();

        verifyReadDeadline();

        verifyUncertainWrites();

        auto final = sqlPoolStats();
        check(final.outstanding == 0 && final.queryBytes == 0,
              "all query allocations and completions released");
        cout << "SQLPOOL METRIC accepted=" << final.accepted << " rejected=" << final.rejected
             << " peak_jobs=" << final.peakJobs << " peak_query_bytes=" << final.peakBytes
             << " max_wait_ms=" << final.maxWaitMs << " max_execution_ms=" << final.maxExecutionMs
             << endl;
        check(threadCount() == threads, "query volume does not create additional worker threads");
        sqlPoolShutdown();
        cout << "SQLPOOL COMPLETE checks=" << checks << endl;
        return 0;
    } catch(const exception &error) {
        cout << "SQLPOOL FAILURE " << error.what() << endl;
        sqlPoolShutdown();
        return 1;
    }
}
