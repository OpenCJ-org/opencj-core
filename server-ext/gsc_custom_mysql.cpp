#include "gsc_custom_mysql.hpp"
#include "mysql_async_pool.hpp"
#include "opencj_demo.hpp"

#include <mysql/mysql.h>
#include <mysql/errmsg.h>
#include <pthread.h>
#include <unistd.h>
#include <strings.h>

// Load library headers before engine headers that change structure packing.
#include "shared.hpp"

#define SQL_MAX_QUERY_SIZE  (10 * 1024)

// Keep polling bounded so many completed queries do not consume a whole frame.
static const int SQL_DEFAULT_QUEUE_WAIT_MS = 10000;
static const int SQL_DONE_SCAN_CAPACITY = 512;
static const int SQL_MAX_PUBLISHED_COMPLETIONS = 64;
static const int SQL_DEMO_DECODE_BUDGET_MS = 4;

MYSQL *cod_mysql_connection = NULL;
static bool sync_mysql_transaction = false;
static bool sync_mysql_failed_transaction = false;

// Only connection probes may be repeated; the SQL statement is submitted once.
// After a killed connection, the first probe can report the old connection's
// loss before a subsequent probe can reconnect.
static int mysql_prepare_new_statement(MYSQL *connection)
{
    int error = mysql_ping(connection);
    if (error && (mysql_errno(connection) == CR_SERVER_LOST ||
                  mysql_errno(connection) == CR_SERVER_GONE_ERROR))
    {
        // mysql_options(RECONNECT) emits a warning in newer clients; only
        // change it during recovery, not on every healthy query.
        bool reconnect = true;
        mysql_options(connection, MYSQL_OPT_RECONNECT, &reconnect);
        error = mysql_ping(connection);
        if (error && (mysql_errno(connection) == CR_SERVER_LOST ||
                      mysql_errno(connection) == CR_SERVER_GONE_ERROR))
        {
            error = mysql_ping(connection);
        }
        reconnect = false;
        mysql_options(connection, MYSQL_OPT_RECONNECT, &reconnect);
    }
    return error;
}

// CALL returns a trailing status result even when it selects only one rowset.
// Buffer the first rowset for GSC, then drain the rest before reusing the connection.
static MYSQL_RES *mysql_store_first_result(MYSQL *connection, bool *failed)
{
    MYSQL_RES *firstResult = mysql_store_result(connection);
    *failed = mysql_errno(connection) != 0;
    while (!*failed && mysql_more_results(connection))
    {
        int nextResultStatus = mysql_next_result(connection);
        if (nextResultStatus > 0)
        {
            *failed = true;
            break;
        }
        if (nextResultStatus < 0)
        {
            break;
        }
        MYSQL_RES *extraResult = mysql_store_result(connection);
        *failed = mysql_errno(connection) != 0;
        if (extraResult)
        {
            mysql_free_result(extraResult);
        }
    }
    if (*failed && firstResult)
    {
        mysql_free_result(firstResult);
        firstResult = NULL;
    }
    return firstResult;
}

// Legacy callers receive a positive job ID, or zero when admission fails.
int mysql_async_query_initializer(char *query, bool retainResult)
{
    int jobId = sqlPoolSubmit(query, retainResult, SQL_WRITE, "", "", SQL_DEFAULT_QUEUE_WAIT_MS);
    return jobId > 0 ? jobId : 0;
}

void gsc_mysql_async_create_query_nosave()
{
    char *query = NULL;
    if (!stackGetParams("s", &query))
    {
        stackPushUndefined();
        return;
    }
    int jobId = mysql_async_query_initializer(query, false);
    if (jobId)
    {
        stackPushInt(jobId);
    }
    else
    {
        stackPushUndefined();
    }
}

void gsc_mysql_async_create_query()
{
    char *query = NULL;
    if (!stackGetParams("s", &query))
    {
        stackPushUndefined();
        return;
    }
    int jobId = mysql_async_query_initializer(query, true);
    if (jobId)
    {
        stackPushInt(jobId);
    }
    else
    {
        stackPushUndefined();
    }
}

// Submit explicit scheduling/ownership fields; admission failures are negative outcomes.
void gsc_mysql_async_submit()
{
    char *query = NULL;
    char *orderingKey = NULL;
    char *scope = NULL;
    int policy = SQL_WRITE;
    int queueWaitMs = SQL_DEFAULT_QUEUE_WAIT_MS;
    int retainResult = 1;
    if (!stackGetParams("sissii", &query, &policy, &orderingKey, &scope, &queueWaitMs, &retainResult))
    {
        stackPushInt(-SQL_INVALID);
        return;
    }
    stackPushInt(sqlPoolSubmit(query, retainResult != 0, policy, orderingKey, scope, queueWaitMs));
}

// Poll completions without consuming them; native demo decoding shares one time budget.
void gsc_mysql_async_getdone_list()
{
    int completedJobIds[SQL_DONE_SCAN_CAPACITY];
    int completedCount = sqlPoolDone(completedJobIds, SQL_DONE_SCAN_CAPACITY);
    int publishedCount = 0;
    long long decodeDeadlineMs = OpenCJ_Demo_SQLClockMs() + SQL_DEMO_DECODE_BUDGET_MS;
    stackMakeArray();
    for (int jobIndex = 0; jobIndex < completedCount && publishedCount < SQL_MAX_PUBLISHED_COMPLETIONS; jobIndex++)
    {
        if (OpenCJ_Demo_SQLReady(completedJobIds[jobIndex], decodeDeadlineMs))
        {
            stackPushInt(completedJobIds[jobIndex]);
            stackPushArrayNext();
            ++publishedCount;
        }
    }
}

void gsc_mysql_async_getstatus()
{
    int jobId = 0;
    SqlCompletion completion;
    if (!stackGetParams("i", &jobId) || !sqlPoolStatus(jobId, &completion))
    {
        stackPushUndefined();
        return;
    }
    stackMakeArray();
    OpenCJ_Demo_SQLStatus(jobId, &completion);
    // This order is the status tuple decoded by mysql.gsc.
    const int values[] = {
        completion.outcome,
        completion.error,
        completion.waitMs,
        completion.executionMs,
    };
    for (int value : values)
    {
        stackPushInt(value);
        stackPushArrayNext();
    }
}

// Consume the job and transfer its rowset to GSC, which must free that rowset.
void gsc_mysql_async_getresult_and_free()
{
    int jobId = 0;
    SqlCompletion completion;
    MYSQL_RES *result = NULL;
    if (!stackGetParams("i", &jobId) || !sqlPoolTake(jobId, &result, &completion))
    {
        stackPushUndefined();
        return;
    }
    if (completion.outcome != SQL_OK)
    {
        if (result)
        {
            mysql_free_result(result);
        }
        stackPushUndefined();
    }
    else
    {
        stackPushInt((int)result);
    }
}

// Translate script flags into explicit native cancellation choices.
void gsc_mysql_async_cancel()
{
    char *scope = NULL;
    int prefix = 0;
    int forget = 0;
    if (!stackGetParams("sii", &scope, &prefix, &forget))
    {
        stackPushUndefined();
        return;
    }

    const SqlScopeMatch scopeMatch = prefix ? SqlScopeMatch::Prefix : SqlScopeMatch::Exact;
    const SqlCompletionHandling completionHandling =
        forget ? SqlCompletionHandling::Discard : SqlCompletionHandling::Retain;
    sqlPoolCancel(scope, scopeMatch, completionHandling);
    stackPushInt(1);
}

// Cancel native transfer ownership before discarding the old map's pool completions.
void gsc_mysql_async_newmap()
{
    OpenCJ_Demo_SQLNewMap();
    sqlPoolNewMap();
    stackPushInt(1);
}

void gsc_mysql_async_stats()
{
    SqlPoolStats stats = sqlPoolStats();
    // Preserve the script-visible statistics order used by monitoring and fixtures.
    const int values[] = {
        stats.workers,
        stats.queued,
        stats.running,
        stats.completed,
        stats.outstanding,
        stats.queryBytes,
        stats.peakJobs,
        stats.peakBytes,
        stats.accepted,
        stats.succeeded,
        stats.failed,
        stats.cancelled,
        stats.rejected,
        stats.expired,
        stats.unknown,
        stats.oldestWaitMs,
        stats.maxWaitMs,
        stats.maxExecutionMs,
    };
    stackMakeArray();
    for (int value : values)
    {
        stackPushInt(value);
        stackPushArrayNext();
    }
}

// Initialize the fixed pool and return slot numbers, never worker-owned connections.
void gsc_mysql_async_initializer()
{
    char *host = NULL;
    char *user = NULL;
    char *password = NULL;
    char *database = NULL;
    int port = 0;
    int workerCount = 0;
    if (!stackGetParams("ssssii", &host, &user, &password, &database, &port, &workerCount) ||
        !sqlPoolInit(host, user, password, database, port, workerCount))
    {
        stackPushUndefined();
        return;
    }
    // Do not expose worker-owned MYSQL pointers to the game thread.
    stackMakeArray();
    for (int workerIndex = 0; workerIndex < workerCount; workerIndex++)
    {
        stackPushInt(workerIndex);
        stackPushArrayNext();
    }
}

void gsc_mysql_init()
{
    MYSQL *connection = mysql_init(NULL);
    if(connection != NULL)
    {
        stackPushInt((int)connection);
    }
    else
    {
        stackPushUndefined();
    }
}

void gsc_mysql_reuse_connection()
{
    if(cod_mysql_connection == NULL)
    {
        stackPushUndefined();
        return;
    }
    else
    {
        stackPushInt((int) cod_mysql_connection);
        return;
    }
}

void gsc_mysql_real_connect()
{
    int connectionHandle = 0;
    int port = 0;
    char *host = NULL;
    char *user = NULL;
    char *password = NULL;
    char *database = NULL;
    if (!stackGetParams("issssi", &connectionHandle, &host, &user, &password, &database, &port))
    {
        stackError(
            "gsc_mysql_real_connect() one or more arguments is undefined or has a wrong type");
        stackPushUndefined();
        return;
    }

    MYSQL *connection = mysql_real_connect((MYSQL *)connectionHandle, host, user, password, database, port, NULL, 0);
    bool reconnect = false;
    if (connection)
    {
        mysql_options(connection, MYSQL_OPT_RECONNECT, &reconnect);
    }
    if (cod_mysql_connection == NULL)
    {
        cod_mysql_connection = (MYSQL *)connection;
    }

    if (connection != NULL)
    {
        stackPushInt((int)connection);
    }
    else
    {
        stackPushUndefined();
    }
}


void gsc_mysql_error()
{
	int mysql = 0;
	if (!stackGetParams("i", &mysql))
	{
		stackError("gsc_mysql_error() argument is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}

	char *ret = (char *)mysql_error((MYSQL *)mysql);
	stackPushString(ret);
}

void gsc_mysql_errno()
{
	int mysql = 0;
	if (!stackGetParams("i", &mysql))
	{
		stackError("gsc_mysql_errno() argument is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}

	int ret = mysql_errno((MYSQL *)mysql);
	stackPushInt(ret);
}

void gsc_mysql_close()
{
    int connectionHandle = 0;
    if (!stackGetParams("i", &connectionHandle))
    {
        stackError("gsc_mysql_close() argument is undefined or has a wrong type");
        stackPushUndefined();
        return;
    }

    if ((MYSQL *)connectionHandle == cod_mysql_connection)
    {
        cod_mysql_connection = NULL;
        sync_mysql_transaction = false;
        sync_mysql_failed_transaction = false;
    }
    mysql_close((MYSQL *)connectionHandle);
    stackPushInt(0);
}

// Submit once. A failed transaction must be rolled back before further shared queries.
void gsc_mysql_query()
{
    int connectionHandle = 0;
    char *query = NULL;
    if (!stackGetParams("is", &connectionHandle, &query))
    {
        stackError("gsc_mysql_query() one or more arguments is undefined or has a wrong type");
        stackPushUndefined();
        return;
    }

    MYSQL *connection = (MYSQL *)connectionHandle;
    bool isSharedConnection = connection == cod_mysql_connection;
    bool isRollback = strcasecmp(query, "ROLLBACK") == 0;
    if (isSharedConnection && sync_mysql_failed_transaction && !isRollback)
    {
        stackPushInt(1);
        return;
    }
    if (isSharedConnection && !sync_mysql_transaction && !sync_mysql_failed_transaction)
    {
        int connectionError = mysql_prepare_new_statement(connection);
        if (connectionError)
        {
            stackPushInt(connectionError);
            return;
        }
    }
    int queryError = mysql_query(connection, query);
    if (isSharedConnection)
    {
        if (queryError && sync_mysql_transaction)
        {
            sync_mysql_failed_transaction = true;
        }
        // SELECT status is final only after its rowset has been consumed.
        if (!queryError && mysql_field_count(connection) == 0)
        {
            sync_mysql_transaction = (connection->server_status & SERVER_STATUS_IN_TRANS) != 0;
        }
        if (isRollback)
        {
            sync_mysql_transaction = false;
            sync_mysql_failed_transaction = false;
        }
    }
    stackPushInt(queryError);
}

void gsc_mysql_affected_rows()
{
	int mysql = 0;
	if (!stackGetParams("i", &mysql))
	{
		stackError("gsc_mysql_affected_rows() argument is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}

	int ret = mysql_affected_rows((MYSQL *)mysql);
	stackPushInt(ret);
}

// Drain every CALL result while retaining the first rowset for the script caller.
void gsc_mysql_store_result()
{
    int connectionHandle = 0;
    if (!stackGetParams("i", &connectionHandle))
    {
        stackError("gsc_mysql_store_result() argument is undefined or has a wrong type");
        stackPushUndefined();
        return;
    }

    MYSQL *connection = (MYSQL *)connectionHandle;
    bool failed = false;
    MYSQL_RES *result = mysql_store_first_result(connection, &failed);
    if (failed)
    {
        if (connection == cod_mysql_connection && sync_mysql_transaction)
        {
            sync_mysql_failed_transaction = true;
        }
        stackPushUndefined();
    }
    else
    {
        if (connection == cod_mysql_connection)
        {
            sync_mysql_transaction =
                (connection->server_status & SERVER_STATUS_IN_TRANS) != 0;
        }
        stackPushInt((int)result);
    }
}

void gsc_mysql_num_rows()
{
	int result = 0;
	if (!stackGetParams("i", &result))
	{
		stackError("gsc_mysql_num_rows() argument is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}

	int ret = mysql_num_rows((MYSQL_RES *)result);
	stackPushInt(ret);
}

void gsc_mysql_num_fields()
{
	int result = 0;
	if (!stackGetParams("i", &result))
	{
		stackError("gsc_mysql_num_fields() argument is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}

	int ret = mysql_num_fields((MYSQL_RES *)result);
	stackPushInt(ret);
}

void gsc_mysql_field_seek()
{
	int result = 0, offset = 0;
	if (!stackGetParams("ii", &result, &offset))
	{
		stackError("gsc_mysql_field_seek() one or more arguments is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}

	int ret = mysql_field_seek((MYSQL_RES *)result, offset);
	stackPushInt(ret);
}

void gsc_mysql_fetch_field()
{
	int result = 0;
	if (!stackGetParams("i", &result))
	{
		stackError("gsc_mysql_fetch_field() argument is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}

	MYSQL_FIELD *field = mysql_fetch_field((MYSQL_RES *)result);
	if (field == NULL)
	{
		stackPushUndefined();
		return;
	}

	char *ret = field->name;
	stackPushString(ret);
}

void gsc_mysql_fetch_row()
{
	int result = 0;
	if (!stackGetParams("i", &result))
	{
		stackError("gsc_mysql_fetch_row() argument is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}

	MYSQL_ROW row = mysql_fetch_row((MYSQL_RES *)result);
	if (!row)
	{
		stackPushUndefined();                   
		return;
	}

	stackMakeArray();
	int numfields = mysql_num_fields((MYSQL_RES *)result);
	for (int i = 0; i < numfields; i++)
	{
		if (row[i] == NULL)
        {
			stackPushUndefined();
        }
        else
		{
        	stackPushString(row[i]);
        }

		stackPushArrayNext();                      
	}
}

void gsc_mysql_free_result()
{
                                                      
	int result = 0;
	if (!stackGetParams("i", &result))
	{
		stackError("gsc_mysql_free_result() argument is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}

	if (result == 0)
	{
		stackError("mysql_free_result() input is a NULL-pointer");
		stackPushUndefined();
		return;
	}

	mysql_free_result((MYSQL_RES *)result);
	stackPushUndefined();
}

void gsc_mysql_real_escape_string()
{
	int mysql = 0;
	char *str = NULL;
	if (!stackGetParams("is", &mysql, &str))
	{
		stackError("gsc_mysql_real_escape_string() one or more arguments is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}

	char *to = (char *)malloc(strlen(str) * 2 + 1);
	mysql_real_escape_string((MYSQL *)mysql, to, str, strlen(str));
	stackPushString(to);
	free(to);
}

// A script-owned builder from setup until free or execute; a failed append poisons it.
struct mysql_long_query
{
    bool failed;
    char text[SQL_MAX_QUERY_SIZE + 1];
};

void gsc_mysql_setup_longquery()
{
    mysql_long_query *longQuery = (mysql_long_query *)calloc(1, sizeof(mysql_long_query));
    if (longQuery)
    {
        stackPushInt((int)longQuery);
    }
    else
    {
        stackPushInt(-1);
    }
}

void gsc_mysql_free_longquery()
{
    if (Scr_GetNumParam() != 1)
    {
        stackError("FreeLongQuery expected 1 param: <HANDLE>");
        stackPushBool(false);
        return;
    }

    int queryHandle = -1;
    stackGetParamInt(0, &queryHandle);
    if (queryHandle <= 0)
    {
        stackError("FreeLongQuery called with invalid handle!");
        stackPushBool(false);
        return;
    }
    mysql_long_query *longQuery = (mysql_long_query *)queryHandle;

    free(longQuery);
    stackPushBool(true);
}

void gsc_mysql_append_longquery()
{
    if (Scr_GetNumParam() != 2)
    {
        stackError("AppendLongQuery expected 2 params: <HANDLE> <text to append>");
        stackPushBool(false);
        return;
    }

    int queryHandle = -1;
    stackGetParamInt(0, &queryHandle);
    if (queryHandle <= 0)
    {
        stackError("AppendLongQuery called with invalid handle!");
        stackPushBool(false);
        return;
    }
    mysql_long_query *longQuery = (mysql_long_query *)queryHandle;

    char *queryPart = NULL;
    stackGetParamString(1, &queryPart);
    if (!queryPart)
    {
        stackError("AppendLongQuery called with NULL append string!");
        stackPushBool(false);
        return;
    }

    int partLength = strlen(queryPart);
    if (partLength == 0)
    {
        printf("AppendLongQuery called with empty append string\n");
        stackPushBool(true);
        return;
    }

    if (longQuery->failed || (strlen(longQuery->text) + partLength) > SQL_MAX_QUERY_SIZE)
    {
        longQuery->failed = true;
        stackPushBool(false);
        return;
    }

    strcat(longQuery->text, queryPart);
    stackPushBool(true);
}

void gsc_mysql_async_execute_longquery()
{
    int argumentCount = Scr_GetNumParam();
    if ((argumentCount > 2) || (argumentCount < 1))
    {
        stackError("ExecuteLongQuery expects between 1 and 2 arguments: <handle> [save]");
        stackPushUndefined();
        return;
    }

    int queryHandle = -1;
    stackGetParamInt(0, &queryHandle);
    if (queryHandle <= 0)
    {
        stackError("ExecuteLongQuery called with invalid handle!");
        stackPushBool(false);
        return;
    }

    int retainResult = 1;
    if (Scr_GetNumParam() > 1)
    {
        stackGetParamInt(1, &retainResult);
    }

    mysql_long_query *longQuery = (mysql_long_query *)queryHandle;
    int queryId = longQuery->failed ? 0 : mysql_async_query_initializer(longQuery->text, retainResult > 0);
    // Admission copies the SQL; this consumes the builder even if admission fails.
    free(longQuery);

    if (queryId)
    {
        stackPushInt(queryId);
    }
    else
    {
        stackPushUndefined();
    }
}

// Collect regular rowsets or small native-transfer receipts through one path.
// Binary demo payloads are decoded before this function becomes eligible.
void gsc_mysql_async_getrows_and_free()
{
    int jobId;
    if (!stackGetParams("i", &jobId))
    {
        stackPushUndefined();
        return;
    }
    if (OpenCJ_Demo_SQLTake(jobId))
    {
        return;
    }
    SqlCompletion completion;
    MYSQL_RES *result = nullptr;
    if (!sqlPoolTake(jobId, &result, &completion))
    {
        stackPushUndefined();
        return;
    }
    if (completion.outcome != SQL_OK)
    {
        if (result)
        {
            mysql_free_result(result);
        }
        stackPushUndefined();
        return;
    }
    stackMakeArray();
    if (!result)
    {
        return;
    }
    const unsigned fieldCount = mysql_num_fields(result);
    MYSQL_ROW row = mysql_fetch_row(result);
    while (row)
    {
        stackMakeArray();
        for (unsigned fieldIndex = 0; fieldIndex < fieldCount; fieldIndex++)
        {
            if (row[fieldIndex])
            {
                stackPushString(row[fieldIndex]);
            }
            else
            {
                stackPushUndefined();
            }
            stackPushArrayNext();
        }
        stackPushArrayNext();
        row = mysql_fetch_row(result);
    }
    mysql_free_result(result);
}
