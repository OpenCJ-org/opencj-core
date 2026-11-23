/*
    Spike: Had the problem, that a query failed but no mysql_errno() was set
    Reason: mysql_query() didnt even got executed, because the str was undefined
    So the function quittet with Plugin_Scr_AddInt(0)
    Now its undefined, and i shall test it every time
*/

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
    MYSQL_RES *first = mysql_store_result(connection);
    *failed = mysql_errno(connection) != 0;
    while (!*failed && mysql_more_results(connection))
    {
        int next = mysql_next_result(connection);
        if (next > 0)
        {
            *failed = true;
            break;
        }
        if (next < 0)
        {
            break;
        }
        MYSQL_RES *extra = mysql_store_result(connection);
        *failed = mysql_errno(connection) != 0;
        if (extra)
        {
            mysql_free_result(extra);
        }
    }
    if (*failed && first)
    {
        mysql_free_result(first);
        first = NULL;
    }
    return first;
}

int mysql_async_query_initializer(char *sql, bool save)
{
    int id = sqlPoolSubmit(sql, save, SQL_WRITE, "", "", 10000);
    return id > 0 ? id : 0;
}

void gsc_mysql_async_create_query_nosave()
{
    char *query = NULL;
    if (!stackGetParams("s", &query))
    {
        stackPushUndefined();
        return;
    }
    int id = mysql_async_query_initializer(query, false);
    if (id)
    {
        stackPushInt(id);
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
    int id = mysql_async_query_initializer(query, true);
    if (id)
    {
        stackPushInt(id);
    }
    else
    {
        stackPushUndefined();
    }
}
void gsc_mysql_async_submit()
{
    char *query = NULL;
    char *key = NULL;
    char *scope = NULL;
    int policy = SQL_WRITE;
    int deadline = 10000;
    int save = 1;
    if (!stackGetParams("sissii", &query, &policy, &key, &scope, &deadline, &save))
    {
        stackPushInt(-SQL_INVALID);
        return;
    }
    stackPushInt(sqlPoolSubmit(query, save != 0, policy, key, scope, deadline));
}
void gsc_mysql_async_getdone_list()
{
    int ids[512];
    int count = sqlPoolDone(ids, 512);
    int published = 0;
    long long deadline = OpenCJ_Demo_SQLClockMs() + 4;
    stackMakeArray();
    for (int i = 0; i < count && published < 64; i++)
    {
        if (OpenCJ_Demo_SQLReady(ids[i], deadline))
        {
            stackPushInt(ids[i]);
            stackPushArrayNext();
            ++published;
        }
    }
}
void gsc_mysql_async_getstatus()
{
    int id = 0;
    SqlCompletion c;
    if (!stackGetParams("i", &id) || !sqlPoolStatus(id, &c))
    {
        stackPushUndefined();
        return;
    }
    stackMakeArray();
    OpenCJ_Demo_SQLStatus(id, &c);
    int values[] = {c.outcome, c.error, c.waitMs, c.executionMs};
    for (int i = 0; i < 4; i++)
    {
        stackPushInt(values[i]);
        stackPushArrayNext();
    }
}
void gsc_mysql_async_getresult_and_free()
{
    int id = 0;
    SqlCompletion c;
    MYSQL_RES *result = NULL;
    if (!stackGetParams("i", &id) || !sqlPoolTake(id, &result, &c))
    {
        stackPushUndefined();
        return;
    }
    if (c.outcome != SQL_OK)
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

void gsc_mysql_async_newmap()
{
    OpenCJ_Demo_SQLNewMap();
    sqlPoolNewMap();
    stackPushInt(1);
}
void gsc_mysql_async_stats()
{
    SqlPoolStats s = sqlPoolStats();
    int values[] = {s.workers,      s.queued,    s.running,       s.completed, s.outstanding,
                    s.queryBytes,   s.peakJobs,  s.peakBytes,     s.accepted,  s.succeeded,
                    s.failed,       s.cancelled, s.rejected,      s.expired,   s.unknown,
                    s.oldestWaitMs, s.maxWaitMs, s.maxExecutionMs};
    stackMakeArray();
    for (int i = 0; i < 18; i++)
    {
        stackPushInt(values[i]);
        stackPushArrayNext();
    }
}
void gsc_mysql_async_initializer()
{
    char *host = NULL;
    char *user = NULL;
    char *pass = NULL;
    char *db = NULL;
    int port = 0;
    int count = 0;
    if (!stackGetParams("ssssii", &host, &user, &pass, &db, &port, &count) ||
        !sqlPoolInit(host, user, pass, db, port, count))
    {
        stackPushUndefined();
        return;
    }
    // Do not expose worker-owned MYSQL pointers to the game thread.
    stackMakeArray();
    for (int i = 0; i < 4; i++)
    {
        stackPushInt(i);
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
    int iMysql = 0;
    int port = 0;
    char *host = NULL;
    char *user = NULL;
    char *pass = NULL;
    char *db = NULL;
    if (!stackGetParams("issssi", &iMysql, &host, &user, &pass, &db, &port))
    {
        stackError(
            "gsc_mysql_real_connect() one or more arguments is undefined or has a wrong type");
        stackPushUndefined();
        return;
    }

    MYSQL *mysql = mysql_real_connect((MYSQL *)iMysql, host, user, pass, db, port, NULL, 0);
    bool reconnect = false;
    if (mysql)
    {
        mysql_options(mysql, MYSQL_OPT_RECONNECT, &reconnect);
    }
    if (cod_mysql_connection == NULL)
    {
        cod_mysql_connection = (MYSQL *)mysql;
    }

    if (mysql != NULL)
    {
        stackPushInt((int)mysql);
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
    int mysql = 0;
    if (!stackGetParams("i", &mysql))
    {
        stackError("gsc_mysql_close() argument is undefined or has a wrong type");
        stackPushUndefined();
        return;
    }

    if ((MYSQL *)mysql == cod_mysql_connection)
    {
        cod_mysql_connection = NULL;
        sync_mysql_transaction = false;
        sync_mysql_failed_transaction = false;
    }
    mysql_close((MYSQL *)mysql);
    stackPushInt(0);
}

void gsc_mysql_query()
{
    int mysql = 0;
    char *query = NULL;
    if (!stackGetParams("is", &mysql, &query))
    {
        stackError("gsc_mysql_query() one or more arguments is undefined or has a wrong type");
        stackPushUndefined();
        return;
    }

    MYSQL *connection = (MYSQL *)mysql;
    bool tracked = connection == cod_mysql_connection;
    bool rollback = strcasecmp(query, "ROLLBACK") == 0;
    if (tracked && sync_mysql_failed_transaction && !rollback)
    {
        stackPushInt(1);
        return;
    }
    if (tracked && !sync_mysql_transaction && !sync_mysql_failed_transaction)
    {
        int ping = mysql_prepare_new_statement(connection);
        if (ping)
        {
            stackPushInt(ping);
            return;
        }
    }
    int ret = mysql_query(connection, query);
    if (tracked)
    {
        if (ret && sync_mysql_transaction)
        {
            sync_mysql_failed_transaction = true;
        }
        // SELECT status is final only after its rowset has been consumed.
        if (!ret && mysql_field_count(connection) == 0)
        {
            sync_mysql_transaction = (connection->server_status & SERVER_STATUS_IN_TRANS) != 0;
        }
        if (rollback)
        {
            sync_mysql_transaction = false;
            sync_mysql_failed_transaction = false;
        }
    }
    stackPushInt(ret);
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

void gsc_mysql_store_result()
{
    int mysql = 0;
    if (!stackGetParams("i", &mysql))
    {
        stackError("gsc_mysql_store_result() argument is undefined or has a wrong type");
        stackPushUndefined();
        return;
    }

    bool failed = false;
    MYSQL_RES *result = mysql_store_first_result((MYSQL *)mysql, &failed);
    if (failed)
    {
        if ((MYSQL *)mysql == cod_mysql_connection && sync_mysql_transaction)
        {
            sync_mysql_failed_transaction = true;
        }
        stackPushUndefined();
    }
    else
    {
        if ((MYSQL *)mysql == cod_mysql_connection)
        {
            sync_mysql_transaction =
                (((MYSQL *)mysql)->server_status & SERVER_STATUS_IN_TRANS) != 0;
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

    int ptr = -1;
    stackGetParamInt(0, &ptr);
    if (ptr <= 0)
    {
        stackError("FreeLongQuery called with invalid handle!");
        stackPushBool(false);
        return;
    }
    mysql_long_query *longQuery = (mysql_long_query *)ptr;

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

    int ptr = -1;
    stackGetParamInt(0, &ptr);
    if (ptr <= 0)
    {
        stackError("AppendLongQuery called with invalid handle!");
        stackPushBool(false);
        return;
    }
    mysql_long_query *longQuery = (mysql_long_query *)ptr;

    char *toAppend = NULL;
    stackGetParamString(1, &toAppend);
    if (!toAppend)
    {
        stackError("AppendLongQuery called with NULL append string!");
        stackPushBool(false);
        return;
    }

    int lenToAppend = strlen(toAppend);
    if (lenToAppend == 0)
    {
        printf("AppendLongQuery called with empty append string\n");
        stackPushBool(true); // Sure, why not
        return;
    }

    if (longQuery->failed || (strlen(longQuery->text) + lenToAppend) > SQL_MAX_QUERY_SIZE)
    {
        longQuery->failed = true;
        stackPushBool(false);
        return;
    }

    strcat(longQuery->text, toAppend);
    stackPushBool(true);
}

void gsc_mysql_async_execute_longquery()
{
    int numParams = Scr_GetNumParam();
    if ((numParams > 2) || (numParams < 1))
    {
        stackError("ExecuteLongQuery expects between 1 and 2 arguments: <handle> [save]");
        stackPushUndefined();
        return;
    }

    int ptr = -1;
    stackGetParamInt(0, &ptr);
    if (ptr <= 0)
    {
        stackError("ExecuteLongQuery called with invalid handle!");
        stackPushBool(false);
        return;
    }

    int save = 1;
    if (Scr_GetNumParam() > 1)
    {
        stackGetParamInt(1, &save);
    }

    mysql_long_query *longQuery = (mysql_long_query *)ptr;
    // printf("Executing long query: %s\n", longQuery);
    int queryId = longQuery->failed ? 0 : mysql_async_query_initializer(longQuery->text, save > 0);
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
    int id;
    if (!stackGetParams("i", &id))
    {
        stackPushUndefined();
        return;
    }
    if (OpenCJ_Demo_SQLTake(id))
    {
        return;
    }
    SqlCompletion c;
    MYSQL_RES *result = nullptr;
    if (!sqlPoolTake(id, &result, &c))
    {
        stackPushUndefined();
        return;
    }
    if (c.outcome != SQL_OK)
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
    MYSQL_ROW row;
    unsigned fields = mysql_num_fields(result);
    while ((row = mysql_fetch_row(result)))
    {
        stackMakeArray();
        for (unsigned i = 0; i < fields; i++)
        {
            if (row[i])
            {
                stackPushString(row[i]);
            }
            else
            {
                stackPushUndefined();
            }
            stackPushArrayNext();
        }
        stackPushArrayNext();
    }
    mysql_free_result(result);
}
