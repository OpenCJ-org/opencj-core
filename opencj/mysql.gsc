#include openCJ\util;

onInit()
{
    level.database = [];
    level.database["host"] = getCvar("db_host");
    level.database["user"] = getCvar("db_user");;
    level.database["pass"] = getCvar("db_pass");
    level.database["port"] = int(getCvar("db_port"));
    level.database["name"] = getCvar("db_base") + getCodVersion();

    level.mySQL = mysql_reuse_connection();
    if(!isDefined(level.mySQL))
    {
        level.mySQL = mysql_init();
        if (!isDefined(level.mySQL)) return;
        ret = mysql_real_connect(level.mySQL, level.database["host"], level.database["user"], level.database["pass"], level.database["name"], level.database["port"]);
        if(!isDefined(ret) || !ret)
        {
            printf("ERROR: MYSQL errno=" + mysql_errno(level.mySQL) + " error= " + mysql_error(level.mySQL) + "\n");
            mysql_close(level.mySQL);
            level.mySQL = undefined;
            return;
        }
    }
    mysql_async_newmap();
    thread _asyncMySQL();
}

_asyncMySQL()
{
    mysql_async_initializer(level.database["host"], level.database["user"], level.database["pass"], level.database["name"], level.database["port"], 4);
    while(true)
    {
        list = mysql_async_getdone_list();
        for(i = 0; i < list.size; i++)
        {
            outcome = mysql_async_getstatus(list[i]);
            result = mysql_async_getresult_and_free(list[i]);
            rows = _getRowsAndFree(result);
            level notify("mysqlQueryDone" + list[i], rows, outcome);
        }
        wait 0.05;
    }
}

mysqlSyncQuery(query)
{
    if (!isDefined(level.mySQL)) return undefined;
    ret = mysql_query(level.mySQL, query);
    if(isDefined(ret) && !ret)
    {
        result = mysql_store_result(level.mySQL);
        rows = _getRowsAndFree(result);
        return rows;
    }
    return undefined;
}

_getRowsAndFree(result)
{
    rows = [];
    if (!isDefined(result)) return undefined; // SQL failure, not an empty success.
    if (result == 0) return rows; // Successful statement with no rowset.
    rowcount = mysql_num_rows(result);
    for(i = 0; i < rowcount; i++)
    {
        row = mysql_fetch_row(result);
        rows[rows.size] = row;
    }
    mysql_free_result(result);
    return rows;
}

mysqlAsyncLongQuerySetup()
{
    return mysql_setup_longquery();
}

mysqlAsyncLongQueryFree(handle)
{
    return mysql_free_longquery(handle);
}

mysqlAsyncLongQueryAppend(queryID, queryPart)
{
    return mysql_append_longquery(queryID, queryPart);
}

mysqlAsyncLongQueryExecuteSave(queryID)
{
    if(isPlayer(self))
    {
        self endon("disconnect");
    }
    id = mysql_async_execute_longquery(queryID, true);
    if (!isDefined(id)) return undefined;
    level waittill("mysqlQueryDone" + id, rows);
    return rows;
}

// No caller receives an unmanaged MYSQL_RES pointer.
mysqlAsyncQueryNoRows(query)
{
    return mysqlAsyncQueryNosave(query);
}

mysqlAsyncLongQueryExecuteNosave(queryID)
{
    if(isPlayer(self))
    {
        self endon("disconnect");
    }
    id = mysql_async_execute_longquery(queryID, false);
    if (!isDefined(id)) return undefined;
    level waittill("mysqlQueryDone" + id, rows);
    return rows;
}

// Compatibility wrapper: unclassified operations are writes, never guessed
// from the SQL verb. Explicit helpers below select policy/order/cancellation.
mysqlAsyncQuery(query)
{
    result = _request(query, 4, defaultWriteKey(), "", 10000, true);
    if (!isDefined(result)) return undefined;
    return result.rows;
}
mysqlAsyncQueryNosave(query)
{
    result = _request(query, 4, defaultWriteKey(), "", 10000, false);
    if (!isDefined(result)) return undefined;
    if (result.status != 0) _reportFailure(result.status);
    if (!isDefined(result)) return undefined;
    return result.rows;
}
mysqlAsyncRead(query)
{
    result = _request(query, 1, "", "", 10000, true);
    if (!isDefined(result)) return undefined;
    return result.rows;
}
mysqlAsyncWrite(query, key)
{
    result = _request(query, 0, key, "", 10000, true);
    if (!isDefined(result)) return undefined;
    return result.rows;
}
mysqlAsyncWriteNosave(query, key)
{
    result = _request(query, 0, key, "", 10000, false);
    if (!isDefined(result)) return undefined;
    if (result.status != 0) _reportFailure(result.status);
    if (!isDefined(result)) return undefined;
    return result.rows;
}
mysqlAsyncBackground(query, key)
{
    result = _request(query, 2, key, "", 30000, true);
    if (!isDefined(result)) return undefined;
    return result.rows;
}
mysqlAsyncMenuQuery(query, menu)
{
    token=self.sqlMenuTokens[menu];
    scope = "p:" + self getEntityNumber() + ":" + menu;
    result = _request(query, 3, "", scope, 2000, true);
    if (!isDefined(result) || !self menuReadCurrent(token)) return undefined;
    if (result.status != 0 && result.status != 5)
    {
        if (!isDefined(self.sqlBusyNotice) || getTime()-self.sqlBusyNotice>5000)
        {
            self.sqlBusyNotice=getTime();
            self openCJ\util::sendLocalChatMessage("Database busy or unavailable. Please try the menu again.");
        }
    }
    if (!isDefined(result)) return undefined;
    return result.rows;
}

// Structured API for callers needing the precise outcome. Successful empty
// statements remain []; failures have undefined rows and an explicit status.
_request(query, policy, key, scope, deadline, save)
{
    if (isPlayer(self)) self endon("disconnect");
    if (!isDefined(key)) key="";
    result=spawnStruct(); result.rows=undefined; result.error=0;
    result.waitMs=0; result.executionMs=0;
    id=mysql_async_submit(query, policy, key, scope, deadline, int(save));
    if (!isDefined(id)) { result.status=7; return result; }
    if (id<=0) { result.status=0-id; return result; }
    level waittill("mysqlQueryDone"+id, rows, outcome);
    result.rows=rows;
    result.status=outcome[0]; result.error=outcome[1];
    result.waitMs=outcome[2]; result.executionMs=outcome[3];
    return result;
}
_reportFailure(status)
{
    // No SQL or credentials. Player-facing critical callers report their own
    // result; fire-and-forget persistence still has an observable failure.
    printf("OpenCJ SQL: persistence request failed, outcome=" + status + "\n");
    if (isPlayer(self))
        self openCJ\util::sendLocalChatMessage("Database could not confirm that your change was saved.", true);
}
beginMenuRead(menu)
{
    if (!isDefined(self.sqlActiveMenu) || self.sqlActiveMenu!=menu) self cancelMenuReads();
    self.sqlActiveMenu=menu;
    if (!isDefined(self.sqlMenuVersions)) self.sqlMenuVersions=[];
    if (!isDefined(self.sqlMenuTokens)) self.sqlMenuTokens=[];
    if (!isDefined(self.sqlMenuEpoch)) self.sqlMenuEpoch=0;
    version=0;
    if (isDefined(self.sqlMenuVersions[menu])) version=self.sqlMenuVersions[menu];
    version++;
    self.sqlMenuVersions[menu]=version;
    token=spawnStruct();token.menu=menu;token.version=version;token.epoch=self.sqlMenuEpoch;
    self.sqlMenuTokens[menu]=token;
    mysql_async_cancel("p:"+self getEntityNumber()+":"+menu, 0, 0);
    // Superseded frames wake with cancellation and return normally. A helper's
    // endon does not reliably terminate all of its calling frames in this VM.
    wait 0.05;
    return token;
}
menuReadCurrent(token)
{
    return isDefined(token) && isDefined(self.sqlMenuEpoch) &&
        token.epoch==self.sqlMenuEpoch && self.sqlMenuVersions[token.menu]==token.version;
}
cancelMenuReads(menu)
{
    scope="";
    if (isDefined(menu))
    {
        if(menu=="opencj_leaderboard" || menu=="opencj_runsboard")scope="board";
        else if(menu=="opencj_challenges")scope="challenges";
        else if(menu=="opencj_clips")scope="clips";
        else return;
    }
    if(scope!="")
    {
        if(isDefined(self.sqlMenuVersions) && isDefined(self.sqlMenuVersions[scope]))
            self.sqlMenuVersions[scope]++;
        mysql_async_cancel("p:"+self getEntityNumber()+":"+scope,0,0);
        if(isDefined(self.sqlActiveMenu) && self.sqlActiveMenu==scope)self.sqlActiveMenu="";
        return;
    }
    if (!isDefined(self.sqlMenuEpoch)) self.sqlMenuEpoch=0;
    self.sqlMenuEpoch++;
    self.sqlActiveMenu="";
    mysql_async_cancel("p:"+self getEntityNumber()+":", 1, 0);
}

showStats(args)
{
    s=mysql_async_stats();
    self openCJ\util::sendLocalChatMessage("SQL: "+s[0]+" workers | queued "+s[1]+" | running "+s[2]+" | waiting results "+s[3]+" | query bytes "+s[5]);
    self openCJ\util::sendLocalChatMessage("Oldest wait "+s[15]+"ms | max wait "+s[16]+"ms | max execution "+s[17]+"ms | rejected "+s[12]+" | failed "+s[10]+" | uncertain "+s[14]);
}

escapeString(string)
{
    return mysql_real_escape_string(level.mysql, string);
}


defaultWriteKey()
{
    if (!isPlayer(self)) return "";
    if (isDefined(self.login_playerID)) return "player:"+self.login_playerID;
    return "slot:"+self getEntityNumber();
}
