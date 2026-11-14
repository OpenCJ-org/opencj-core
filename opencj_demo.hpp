#ifndef _OPENCJ_DEMO_HPP_
#define _OPENCJ_DEMO_HPP_

//==========================================================================
// Functions that do work for any demo                                        
//==========================================================================

void Gsc_Demo_ClearAllDemos();
void Gsc_Demo_HasKeyFrames();
void Gsc_Demo_NumberOfFrames();
void Gsc_Demo_NumberOfKeyFrames();
void Gsc_Demo_CreateDemo();
void Gsc_Demo_DestroyDemo();
void Gsc_Demo_AddFrame();
void Gsc_Demo_CompleteDemo();

//==========================================================================
// Functions related to playback & control                                        
//==========================================================================

void Gsc_Demo_SelectPlaybackDemo(int playerId);
void Gsc_Demo_ReadFrame_Origin(int playerId);
void Gsc_Demo_ReadFrame_Angles(int playerId);
void Gsc_Demo_ReadFrame_SaveNow(int playerId);
void Gsc_Demo_ReadFrame_LoadNow(int playerId);
void Gsc_Demo_ReadFrame_RPGNow(int playerId);
void Gsc_Demo_SkipFrame(int playerId);
void Gsc_Demo_SkipKeyFrame(int playerId);
void Gsc_Demo_NextFrame(int playerId);
void Gsc_Demo_PrevFrame(int playerId);
void Gsc_Demo_ReadFrame_NextKeyFrame(int playerId);
void Gsc_Demo_ReadFrame_PrevKeyFrame(int playerId);
void Gsc_Demo_ReadFrame_Flags(int playerId);
void Gsc_Demo_ReadFrame_FPS(int playerId);

void Gsc_Demo_EncodeChunk();
void Gsc_Demo_DecodeChunk();
void Gsc_Demo_Truncate();
void Gsc_Demo_FindSegment();

void Gsc_Demo_BeginPresentation(int client);
void Gsc_Demo_ApplyPresentation(int client);
void Gsc_Demo_EndPresentation(int client);
void Gsc_Demo_PlayLanding(int client);
void Gsc_Demo_ReadFrame_Weapon(int client);
void Gsc_Demo_ReadFrame_RPGSound(int client);

#endif // _OPENCJ_DEMO_HPP_

void Gsc_Demo_SeekCheckpoint(int client);

void Gsc_Demo_MarkFailedSince();
void Gsc_Demo_PlaybackStyle(int client);
void Gsc_Demo_PlaybackTime(int client);

void Gsc_Demo_CreateTransient();
void Gsc_Demo_KeepLast();
void Gsc_Demo_ClipInfo();

// Used by snapshot visibility to keep playback bodies private.
bool OpenCJ_Demo_IsPresentationActive(int client);
// Reapply presentation after frozen/linked movement chooses an idle body pose.
void OpenCJ_Demo_ApplyBody(int client);

void Gsc_Demo_FPSReset(int client);
void Gsc_Demo_FPSStore(int client);
void Gsc_Demo_FPSRead(int client);
void Gsc_Demo_FPSStats(int client);

struct SqlCompletion;
long long OpenCJ_Demo_SQLClock();
bool OpenCJ_Demo_SQLReady(int id,long long deadline);
void OpenCJ_Demo_SQLStatus(int id,SqlCompletion*);
bool OpenCJ_Demo_SQLTake(int id);
void OpenCJ_Demo_SQLNewMap();
void Gsc_Demo_LoadChunks();
void Gsc_Demo_UploadChunk();
void Gsc_Demo_Pin();
void Gsc_Demo_Unpin();


void Gsc_Demo_CopyHistory();
void Gsc_Demo_RangeInfo();

void Gsc_Demo_ReadFrame_Checkpoint(int client);
