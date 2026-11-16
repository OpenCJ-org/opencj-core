# Deploy client assets

Build from reviewed client-mod sources using a compatible Windows CoD4 Mod Tools
installation. Supply its location explicitly; do not put an operator's paths,
game configuration or credentials in project files.

## Build and compare

1. Stage only the intended source changes in a separate build directory.
   Preserve custom tool files and use the installation's existing makeMod.py.
2. Generate artwork with the documented dependencies and retain component and
   third-party license files in the final package.
3. Inspect the compiled fastfile and IWD, not only the source. Compare changed
   assets, menu definitions, material/image references and package membership.
4. Retain rollback copies privately. Keep source, scripts, native executable
   and client assets from compatible revisions.

The Windows helper requires explicit installation arguments:

```powershell
python source/build_client_assets_windows.py --mod-tools "$env:MOD_TOOLS" --game-dir "$env:GAME_DIR"
```

Run this from its staged private build directory, as described in the
[flag asset guide](../../client-mod/assets/flags/README.md).
The helper validates its placement beneath the selected Mod Tools installation.

## Install and verify

Install matching compiled mod files into the server and client destinations
configured for that deployment. Check hashes and preserve unrelated assets.

A server can keep an old fastfile size/checksum in memory after the file on disk
changes. Matching files alone therefore may not prevent a client download.
When changing a loaded fastfile, fully restart the game server process and
verify the advertised package information before asking clients to reconnect.

Capture the active map and connected players before a restart. Follow the
operator's maintenance policy, preserve other services, and restore the
captured map after restart. Source checkout paths are not deployment targets.

Do not terminate the user's game process to deploy assets. Coordinate reconnect
or mod reload with the player. Verify the intended visual result in game and
retain installation-specific evidence privately.
