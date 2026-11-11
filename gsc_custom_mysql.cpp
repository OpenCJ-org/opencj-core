/*
    Spike: Had the problem, that a query failed but no mysql_errno() was set
    Reason: mysql_query() didnt even got executed, because the str was undefined
    So the function quittet with Plugin_Scr_AddInt(0)
    Now its undefined, and i shall test it every time
*/

#include "gsc_custom_mysql.hpp"

#include <mysql/mysql.h>
#include <mysql/errmsg.h>
#include <pthread.h>
#include <unistd.h>
#include <strings.h>

// Load library headers before engine headers that change structure packing.
#include "shared.hpp"

#define SQL_MAX_QUERY_SIZE  (10 * 1024)

struct mysql_async_task
{
    mysql_async_task *prev;
    mysql_async_task *next;
    int id;
    MYSQL_RES *result;
    bool done;
    bool failed;
    bool started;
    bool save;
    char query[SQL_MAX_QUERY_SIZE + 1];
};

struct mysql_async_connection
{
    mysql_async_connection *prev;
    mysql_async_connection *next;
    mysql_async_task* task;
    MYSQL *connection;
};

mysql_async_connection *first_async_connection = NULL;
mysql_async_task *first_async_task = NULL;
MYSQL *cod_mysql_connection = NULL;
// The GSC synchronous wrapper owns this connection between BEGIN and ROLLBACK/
// COMMIT. Never reconnect halfway through that transaction.
static bool sync_mysql_transaction = false;
static bool sync_mysql_failed_transaction = false;
pthread_mutex_t lock_async_mysql = PTHREAD_MUTEX_INITIALIZER;

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
            error = mysql_ping(connection);
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
        if (next > 0) { *failed = true; break; }
        if (next < 0) break;
        MYSQL_RES *extra = mysql_store_result(connection);
        *failed = mysql_errno(connection) != 0;
        if (extra) mysql_free_result(extra);
    }
    if (*failed && first)
    {
        mysql_free_result(first);
        first = NULL;
    }
    return first;
}

void *mysql_async_execute_query(void *input_c)
{
    mysql_async_connection *c = (mysql_async_connection *) input_c;
    mysql_async_task *task = c->task;
    // Connections are used by one worker at a time, but each new pthread still
    // needs its own client-library thread state.
    bool initialized = mysql_thread_init() == 0;
    bool failed = !initialized;
    if (!failed)
    {
        // Reconnect before submitting a new statement, never replay a statement
        // whose commit outcome is unknown after a connection failure.
        failed = mysql_prepare_new_statement(c->connection) != 0;
        if (!failed) failed = mysql_query(c->connection, task->query) != 0;
    }
    MYSQL_RES *result = NULL;
    if (!failed) result = mysql_store_first_result(c->connection, &failed);
    if (!task->save && result)
    {
        mysql_free_result(result);
        result = NULL;
    }
    if (initialized) mysql_thread_end();
    // Publish the result/status together before the main thread can free the task
    // or the scheduler can reuse this connection.
    pthread_mutex_lock(&lock_async_mysql);
    task->result = result;
    task->failed = failed;
    task->done = true;
    c->task = NULL;
    pthread_mutex_unlock(&lock_async_mysql);
    return NULL;
}

void *mysql_async_query_handler(void* input_nothing) //is threaded after initialize
{
    static bool started = false;
    if(started)
    {
        Shared_Printf("async handler already started. Returning\n");
        return NULL;
    }
    started = true;
    mysql_async_connection *c = first_async_connection;
    if(c == NULL)
    {
        Shared_Printf("async handler started before any connection was initialized\n"); //this should never happen
        started = false;
        return NULL;
    }
    mysql_async_task *q = NULL;
    while(true)
    {
        pthread_mutex_lock(&lock_async_mysql);
        q = first_async_task;
        c = first_async_connection;
        while(q != NULL)
        {
            if(!q->started)
            {
                while(c != NULL && c->task != NULL)
                {
                    c = c->next;
                }

                if(c == NULL)
                {
                    //out of free connections
                    break;
                }
                q->started = true;
                c->task = q;
                pthread_t query_doer;
                int error = pthread_create(&query_doer, NULL, mysql_async_execute_query, c);
                if(error)
                {
                    // Fail this request and keep dispatching; one resource error
                    // must not strand every current and future script waiter.
                    q->failed = true;
                    q->done = true;
                    c->task = NULL;
                    Shared_Printf("MySQL worker creation failed (%i)\n", error);
                }
                else
                    pthread_detach(query_doer);
                c = c->next;
            }
            q = q->next;
        }
        pthread_mutex_unlock(&lock_async_mysql);
        usleep(10000);
    }
    return NULL;
}

int mysql_async_query_initializer(char *sql, bool save) //cannot be called from gsc, helper function
{
    if (!first_async_connection || strlen(sql) > SQL_MAX_QUERY_SIZE)
        return 0;
    static int id = 0;
    id++;

    pthread_mutex_lock(&lock_async_mysql);

    mysql_async_task *current = first_async_task;
    while((current != NULL) && (current->next != NULL))
    {
        current = current->next;
    }

    mysql_async_task *newtask = new mysql_async_task;
    newtask->id = id;
    memcpy(newtask->query, sql, strlen(sql) + 1);
    newtask->prev = current;
    newtask->result = NULL;
    newtask->save = save;
    newtask->done = false;
    newtask->failed = false;
    newtask->next = NULL;
    newtask->started = false;
    if(current != NULL)
    {
        current->next = newtask;
    }
    else
    {
        first_async_task = newtask;
    }

    pthread_mutex_unlock(&lock_async_mysql);
    return id;
}


void gsc_mysql_async_create_query_nosave()
{
	char *query = NULL;
	if (!stackGetParams("s", &query))
	{
		stackError("gsc_mysql_async_create_query_nosave() argument is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}
	int id = mysql_async_query_initializer(query, false);
	if (id) stackPushInt(id);
	else stackPushUndefined();
}

void gsc_mysql_async_create_query()
{
	char *query = NULL;
	if (!stackGetParams("s", &query))
	{
		stackError("gsc_mysql_async_create_query() argument is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}
	int id = mysql_async_query_initializer(query, true);
	if (id) stackPushInt(id);
	else stackPushUndefined();
}

void gsc_mysql_async_getdone_list()
{
    pthread_mutex_lock(&lock_async_mysql);
    mysql_async_task *current = first_async_task;

    stackMakeArray();
    while (current != NULL)
    {
        if (current->done)
        {
            stackPushInt((int)current->id);
            stackPushArrayNext();
        }
        current = current->next;
    }
    pthread_mutex_unlock(&lock_async_mysql);
}

// Failed/not-ready/missing tasks return undefined; successful writes return 0.
void gsc_mysql_async_getresult_and_free()
{
	int id = 0;
	if (!stackGetParams("i", &id))
	{
		stackError("argument is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}
    pthread_mutex_lock(&lock_async_mysql);
    mysql_async_task *c = first_async_task;
    if (c != NULL)
    {
        while((c != NULL) && (c->id != id))
        {
            c = c->next;
        }
    }
    if (c != NULL)
    {
        if(!c->done)
        {
            stackPushUndefined(); //not done yet
            pthread_mutex_unlock(&lock_async_mysql);
            return;
        }
        if(c->next != NULL)
            c->next->prev = c->prev;
        if(c->prev != NULL)
            c->prev->next = c->next;
        else
            first_async_task = c->next;
        if (c->failed)
        {
            stackPushUndefined();
        }
        else if (c->save)
        {
            int ret = (int)c->result;
            stackPushInt(ret);
        }
        else
        {
            stackPushInt(0);
        }
        delete c;
        pthread_mutex_unlock(&lock_async_mysql);
        return;
    }
    else
    {
        Shared_Printf("mysql async query id not found\n");
        stackPushUndefined();
        pthread_mutex_unlock(&lock_async_mysql);
        return;
    }
}

static void mysql_free_async_connections(mysql_async_connection *c)
{
    while (c)
    {
        mysql_async_connection *next = c->next;
        if (c->connection) mysql_close(c->connection);
        delete c;
        c = next;
    }
}

void gsc_mysql_async_initializer()
{
    if (!first_async_connection)
    {
        int port = 0, count = 0;
        char *host = NULL, *user = NULL, *pass = NULL, *db = NULL;
        if (!stackGetParams("ssssii", &host, &user, &pass, &db, &port, &count) || count <= 0)
        {
            stackPushUndefined();
            return;
        }
        // Build privately; a partial failure must leave initialization retryable.
        mysql_async_connection *head = NULL, *tail = NULL;
        for (int i = 0; i < count; i++)
        {
            mysql_async_connection *c = new mysql_async_connection;
            c->prev = tail;
            c->next = NULL;
            c->task = NULL;
            c->connection = mysql_init(NULL);
            unsigned timeout = 5;
            if (c->connection)
                mysql_options(c->connection, MYSQL_OPT_CONNECT_TIMEOUT, &timeout);
            if (!c->connection || !mysql_real_connect(c->connection, host, user, pass, db, port, NULL, 0))
            {
                // Do not log connection strings or credentials.
                Shared_Printf("MySQL async connection initialization failed\n");
                if (c->connection) mysql_close(c->connection);
                delete c;
                mysql_free_async_connections(head);
                stackPushUndefined();
                return;
            }
            if (tail) tail->next = c;
            else head = c;
            tail = c;
        }
        first_async_connection = head;
        pthread_t handler;
        int error = pthread_create(&handler, NULL, mysql_async_query_handler, NULL);
        if (error)
        {
            first_async_connection = NULL;
            mysql_free_async_connections(head);
            Shared_Printf("MySQL dispatcher creation failed (%i)\n", error);
            stackPushUndefined();
            return;
        }
        pthread_detach(handler);
    }
    // Reinitialization on map changes returns the existing pool.
    stackMakeArray();
    for (mysql_async_connection *c = first_async_connection; c; c = c->next)
    {
        stackPushInt((int)c->connection);
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
	int iMysql = 0, port = 0;
	char *host = NULL, *user = NULL, *pass = NULL, *db = NULL;
	if (!stackGetParams("issssi", &iMysql, &host, &user, &pass, &db, &port))
	{
		stackError("gsc_mysql_real_connect() one or more arguments is undefined or has a wrong type");
		stackPushUndefined();
		return;
	}

	MYSQL *mysql = mysql_real_connect((MYSQL *)iMysql, host, user, pass, db, port, NULL, 0);
	bool reconnect = false;
	if (mysql) mysql_options(mysql, MYSQL_OPT_RECONNECT, &reconnect);
	if(cod_mysql_connection == NULL)
    {
		cod_mysql_connection = (MYSQL*)mysql;
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
        if (ping) { stackPushInt(ping); return; }
    }
    int ret = mysql_query(connection, query);
    if (tracked)
    {
        if (ret && sync_mysql_transaction) sync_mysql_failed_transaction = true;
        // SELECT status is final only after its rowset has been consumed.
        if (!ret && mysql_field_count(connection) == 0)
            sync_mysql_transaction = (connection->server_status & SERVER_STATUS_IN_TRANS) != 0;
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
            sync_mysql_failed_transaction = true;
        stackPushUndefined();
    }
    else
    {
        if ((MYSQL *)mysql == cod_mysql_connection)
            sync_mysql_transaction = (((MYSQL *)mysql)->server_status & SERVER_STATUS_IN_TRANS) != 0;
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
    //printf("Executing long query: %s\n", longQuery);
    int queryId = longQuery->failed ? 0 : mysql_async_query_initializer(longQuery->text, save > 0);
    free(longQuery);

    if (queryId) stackPushInt(queryId);
    else stackPushUndefined();
}
