// Shared result handling for position and checkpoint writes.
isCurrent(runID, instance)
{
    return self openCJ\playerRuns::hasRunID() &&
        self openCJ\playerRuns::getRunID() == runID &&
        self openCJ\playerRuns::getRunInstanceNumber() == instance;
}

resultMessage(runID, instance, rows, subject)
{
    if (!self isCurrent(runID, instance)) return "";
    failure = "Database error while saving " + subject + ".";
    if (!isDefined(rows) || rows.size == 0 || !isDefined(rows[0])) return failure;
    if (isDefined(rows[0][0])) return "";

    // NULL from a guarded routine can mean missing data, not just a takeover.
    owner = self openCJ\mySQL::mysqlAsyncQuery("SELECT instanceNumber FROM playerRuns WHERE runID=" + runID);
    if (!self isCurrent(runID, instance)) return "";
    if (!isDefined(owner)) return failure;
    if (owner.size == 0) return "This run no longer exists. Start a new run.";
    if (isDefined(owner[0][0]) && int(owner[0][0]) != instance)
        return "This run was resumed in another session. Start a new run to continue saving here.";
    return failure;
}
