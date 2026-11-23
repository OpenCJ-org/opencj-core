#include openCJ\util;

main(isAllowedToEle)
{
    if(isDefined(self.clipRecording))
    {
        self.clipRecording.elevated = true;
    }
    self openCJ\elevate::onElevate();
}