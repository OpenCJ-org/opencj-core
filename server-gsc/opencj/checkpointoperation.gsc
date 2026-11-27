// One database operation per checkpoint editor at a time: publication, rename or reset.
// SQL replies arrive on later server frames, so the editor is locked meanwhile: its
// commands, inputs, travel and spawn handling wait, and publishers may temporarily
// point self.cpc at another route's draft. The original editor state is kept here so
// a disconnect can restore it before the draft is saved.

// Start an operation. Returns false while this player's previous one is running.
begin()
{
    if (self isBusy())
    {
        return false;
    }
    operation = spawnStruct();
    operation.editorState = self.cpc;
    operation.transaction = undefined;
    operation.replacedRoutes = [];
    self.cpcOperation = operation;
    return true;
}

isBusy()
{
    return isDefined(self.cpcOperation);
}

// End the operation. An unfinished transaction is rolled back here, so an early
// return never leaves its row locks waiting for the idle timeout.
end()
{
    transaction = self.cpcOperation.transaction;
    if (isDefined(transaction))
    {
        openCJ\mySQL::abandonTransaction(transaction);
    }
    self.cpcOperation = undefined;
}

// Open the operation's transaction; false when the database cannot open one in time.
openTransaction()
{
    self.cpcOperation.transaction = self openCJ\mySQL::beginTransaction();
    return isDefined(self.cpcOperation.transaction);
}

// Run one statement of the transaction; undefined when it or an earlier one failed.
query(sql)
{
    return self openCJ\mySQL::transactionQuery(self.cpcOperation.transaction, sql);
}

// Describe a batched statement and the editor status shown if it fails.
statement(sql, failure)
{
    batchedStatement = spawnStruct();
    batchedStatement.sql = sql;
    batchedStatement.failure = failure;
    return batchedStatement;
}

// Run statements together, in order. Returns one rowset per statement, or undefined
// with self.cpc.status set to the failure of the first statement that did not succeed.
batch(statements)
{
    queries = [];
    for (i = 0; i < statements.size; i++)
    {
        queries[i] = statements[i].sql;
    }
    transaction = self.cpcOperation.transaction;
    rowsets = self openCJ\mySQL::transactionBatch(transaction, queries);
    if (!isDefined(rowsets))
    {
        self.cpc.status = statements[transaction.failedIndex].failure;
        return undefined;
    }
    return rowsets;
}

// Commit; returns the outcome from openCJ\mySQL::commitTransaction.
commit()
{
    return self openCJ\mySQL::commitTransaction(self.cpcOperation.transaction);
}

rollback()
{
    self openCJ\mySQL::rollbackTransaction(self.cpcOperation.transaction);
}

// Layout replacement checks other players and demo saves before its SQL. Remember the
// route so publication can repeat those checks right before COMMIT.
noteReplacedRoute(routeName)
{
    replacedRoutes = self.cpcOperation.replacedRoutes;
    replacedRoutes[replacedRoutes.size] = routeName;
    self.cpcOperation.replacedRoutes = replacedRoutes;
}

replacedRoutes()
{
    return self.cpcOperation.replacedRoutes;
}

// The disconnect callback runs before the operation's thread ends, possibly while a
// publisher has replaced self.cpc. Restore the editor state so the draft can be saved.
// A transaction still open is rolled back. A requested COMMIT still settles; gameplay
// is refreshed once it has, so the published routes do not wait for the next map.
onDisconnect()
{
    if (!self isBusy())
    {
        return;
    }
    transaction = self.cpcOperation.transaction;
    if (isDefined(transaction))
    {
        if (openCJ\mySQL::commitPending(transaction))
        {
            level thread openCJ\checkpointPublish::refreshAfterCommit(transaction);
        }
        else
        {
            openCJ\mySQL::abandonTransaction(transaction);
        }
    }
    self.cpc = self.cpcOperation.editorState;
    self.cpcOperation = undefined;
}

