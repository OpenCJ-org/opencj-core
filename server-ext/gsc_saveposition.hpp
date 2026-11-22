#ifndef _GSC_SAVEPOSITION_HPP_
#define _GSC_SAVEPOSITION_HPP_

#include "shared.hpp"

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

// These numeric results are part of the GSC interface.
enum SaveInsertionStatus
{
    SAVE_INSERTED = 0,
    SAVE_HISTORY_FULL = 1,
    SAVE_NOT_OLDER = 2
};

enum SaveSelectionStatus
{
    SAVE_SELECTED = 0,
    SAVE_HISTORY_EMPTY = 1,
    SAVE_INDEX_UNAVAILABLE = 2
};

// Script methods reject non-player indices with undefined before accessing history.
// Invalid save arguments also return undefined and leave existing history intact.
void gsc_saveposition_initclient(int playerIndex);
void gsc_saveposition_save(int playerIndex);
// Add older history: inserted, full, out of order, or undefined on invalid input/allocation failure.
void gsc_saveposition_addolder(int playerIndex);
// Return count, oldest save number, generation, limit and newest save number, in that order.
void gsc_saveposition_historyinfo(int playerIndex);
// Script arguments: excluded flags, then an optional source player index.
void gsc_saveposition_selectwithoutflag(int playerIndex);
// Script argument: distance from newest save. Return SaveSelectionStatus or undefined
// for invalid arguments. All failed selections clear the prior selected position.
void gsc_saveposition_selectsave(int playerIndex);
void gsc_saveposition_getangles(int playerIndex);
void gsc_saveposition_getorigin(int playerIndex);
void gsc_saveposition_getgroundentity(int playerIndex);
void gsc_saveposition_getexplosivejumps(int playerIndex);
void gsc_saveposition_getdoubleexplosives(int playerIndex);
void gsc_saveposition_getcheckpointid(int playerIndex);
void gsc_saveposition_getflags(int playerIndex);
void gsc_saveposition_getfpsmode(int playerIndex);
void gsc_saveposition_getsavenum(int playerIndex);

#ifdef __cplusplus
}
#endif // __cplusplus

#endif
