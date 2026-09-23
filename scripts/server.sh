#!/usr/bin/env bash
set -euo pipefail
runtime=/workspace/dev-tools/local/runtime
mod="$runtime/mods/opencj"
mkdir -p "$mod"
[[ -f /mod-assets/mod.ff ]] || { echo 'Missing mod.ff in MOD_DIR.' >&2; exit 1; }
[[ -f "$runtime/plugins/libcod4_1_8x.so" ]] || { echo 'Run the build command first.' >&2; exit 1; }
ln -sfn /workspace/server-gsc/opencj "$mod/opencj"
ln -sfn /workspace/server-gsc/maps "$mod/maps"
ln -sfn /mod-assets/mod.ff "$mod/mod.ff"
shopt -s nullglob
assets=(/mod-assets/*.iwd)
(( ${#assets[@]} > 0 )) || { echo 'Missing OpenCJ IWD in MOD_DIR.' >&2; exit 1; }
for asset in "${assets[@]}"; do
    ln -sfn "$asset" "$mod/$(basename "$asset")"
done
cd "$runtime"
# The Steam bridge opens this library relative to the working directory.
if [[ -f /game/steamclient.so ]]; then
    ln -sfn /game/steamclient.so "$runtime/steamclient.so"
fi
exec /workspace/cod4x-server/bin/cod4x18_dedrun \
    +set fs_basepath /game +set fs_homepath "$runtime" +set fs_game mods/opencj \
    +set dedicated 2 +set net_ip 0.0.0.0 +set net_port 28960 \
    +set sv_maxclients 4 +set com_hunkMegs 1024 +set sv_authorizemode 1 \
    +set developer 1 +set g_gametype cj +exec opencj-dev.cfg +map "$START_MAP"
