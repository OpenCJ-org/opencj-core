#ifndef OPENCJ_GSC_COD4_HELPERS_HPP
#define OPENCJ_GSC_COD4_HELPERS_HPP
#include "shared.hpp"
#ifdef COD4
extern "C" {
void Gsc_Cod4_GetAscii();
void Gsc_Cod4_ForceDownloadCvars();
void Gsc_Cod4_FindConfigstringIndex();
void Gsc_Cod4_AddVelocity(int id);
void Gsc_Cod4_GetIP(int id);
void Gsc_Cod4_IsSprinting(int id);
}
#endif
#endif
