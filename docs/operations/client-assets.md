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

## Legacy batch builder

`client-mod/cod4/makeMod.bat` needs a separately installed
[7-Zip](https://www.7-zip.org/download.html). Add its `7z.exe` directory to
`PATH`, or set `OPENCJ_7ZIP` to the full executable path before running the
batch file. The value is an executable path, without surrounding quotes or
extra arguments. Paths containing spaces are supported.

The builder checks tools and staged inputs before changing build output, and
returns failure if copying, linking or archive creation fails. It rejects a
successful linker exit that produced no new fastfile. It still requires the
Windows CoD4 Mod Tools installation.

The canonical Python builder uses Python's archive support and does not require
7-Zip. Its linker wait is limited to 180 seconds; the private Windows helper
uses its existing 45-second limit. Both canonical builders preserve previous
packages when prerequisites are missing. Once a validated build starts, they
invalidate the previous packages so a failed build cannot look newly completed.
Only use outputs from a build that reports success.

The `client-build-unit` tests use synthetic inputs. The manual
`client-build-windows` group exercises the actual batch file with an installed
7-Zip and a synthetic linker compiled by the selected .NET C# compiler. These
checks do not replace a real asset build and compiled-output comparison.

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
