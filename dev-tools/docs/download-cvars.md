# Enable client downloads during connection (#200)

Issue: https://github.com/OpenCJ-dev/server-gsc/issues/200

## Change and purpose

The CoD4 branch of `server-gsc/opencj/cvars.gsc::onInit` now calls the existing
`forceDLCvars()` function. That function is already available in our CoD4x
runtime and registers `cl_allowDownload=1` and `cl_wwwDownload=1` with
`CVAR_SYSTEMINFO | CVAR_ROM` (the existing native code uses `0x48`).

`cl_allowDownload` permits missing server-required files to be downloaded.
`cl_wwwDownload` enables HTTP downloading when the server provides it.
Both normally default to 1 on the client; this covers configurations with
downloads disabled.

Systeminfo is included in the initial game state. Client
`CL_SystemInfoChanged` applies it before `CL_InitDownloads` checks missing
files. This happens during connection, before map loading. The registration
runs at server initialization, not in a callback that requires the player to
have loaded the map already.

The read-only flag applies to the server's registered variables. This change
does not add a permanent client lock or restore a player's previous setting on
disconnect; it sets the client download preferences to 1 through systeminfo.

No native/client asset rebuild is needed. Live server file-delivery settings
and URLs are unchanged. HTTP hosting and access rules remain separate #203 work.
