#include openCJ\util;

main(checkpointPassed)
{
    self openCJ\checkpointPointers::onCheckpointsChanged();
    self openCJ\showRecords::onCheckpointsChanged();
    self openCJ\huds\hudProgressBar::onCheckpointsChanged(checkpointPassed);
    self openCJ\elevate::onCheckpointsChanged();
    self openCJ\statistics::onCheckpointsChanged();

}
