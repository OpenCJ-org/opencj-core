// Shared result handling for position and checkpoint writes.
isCurrent(runID, instanceNumber)
{
    return self openCJ\playerRuns::hasRunID() &&
           self openCJ\playerRuns::getRunID() == runID &&
           self openCJ\playerRuns::getRunInstanceNumber() == instanceNumber;
}

// Explain a failed write only while it still belongs to the player's current run.
resultMessage(runID, instanceNumber, rows, subject)
{
    if(!self isCurrent(runID, instanceNumber))
    {
        return "";
    }

    databaseFailure = "Database error while saving " + subject + ".";
    if(!isDefined(rows) || rows.size == 0 || !isDefined(rows[0]))
    {
        return databaseFailure;
    }
    if(isDefined(rows[0][0]))
    {
        return "";
    }

    // NULL from a guarded routine can mean missing data, not just a takeover.
    ownerRows = self openCJ\mySQL::mysqlAsyncRead(
        "SELECT instanceNumber"
        + " FROM playerRuns"
        + " WHERE runID = " + runID);
    if(!self isCurrent(runID, instanceNumber))
    {
        return "";
    }
    if(!isDefined(ownerRows))
    {
        return databaseFailure;
    }
    if(ownerRows.size == 0)
    {
        return "This run no longer exists. Start a new run.";
    }
    if(isDefined(ownerRows[0][0]))
    {
        currentInstanceNumber = int(ownerRows[0][0]);
        if(currentInstanceNumber != instanceNumber)
        {
            return "This run was resumed in another session. Start a new run to continue saving here.";
        }
    }
    return databaseFailure;
}
