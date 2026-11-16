# CoD4 native helpers without the libcod plugin

CoD4 now registers the required helpers directly from server-ext. The standalone
libcod repository remains the CoD2 implementation. CoD4x's general plugin support
is unchanged, and dedicated test probe plugins can still be used.

## Native interface

server-ext/gsc_cod4_helpers.cpp supplies getAscii, forceDLCvars,
G_FindConfigstringIndex, addVelocity, getIP and isSprinting under COD4 only.
The GSC names remain compatible with existing callers.

- getAscii preserves the old signed first-byte result, including zero for an
  empty string.
- addVelocity preserves component-wise addition and its success result.
- getIP uses the engine's address-only formatter, without manually removing a
  port; it supports IPv4/IPv6 and engine bot/loopback names.
- isSprinting retains the same sprint-start/end state comparison.
- forceDLCvars registers both client download switches with SYSTEMINFO | ROM,
  preserving the #200 initialization behavior.
- Invalid non-player entities return the former plugin's safe empty/zero result.

The existing native getQueuedReliableMessages is reused with a client-index
bounds check. The existing printf now routes CoD4 output through Com_Printf,
matching the plugin's immediate console logging under Docker/services. CoD2
behavior is unchanged.

## HUD lookup correction

G_FindConfigstringIndex(name, start, count) searches existing entries from
start + 1 through start + count - 1. The table's zero slot is reserved. It returns
an **absolute configstring index**, required by the client configstring-update
command, or zero when not found. It validates range arithmetic, including
negative and overflowing inputs, and never creates or changes entries.

The old plugin read only two arguments and scanned indices 1..1309, accidentally
finding CoD4 strings despite the wrong table argument. CoD4's actual localized
table starts at 309 and spans 512 entries (verified in G_LocalizedStringIndex in
src/asmsource/_g_utils_mp.asm). The production GSC wrapper now selects that range.
The original CoD2 range remains 1310/256.

## Build, startup and test tools

The standard CoD4 build includes server-ext automatically. scripts/build.sh no
longer builds/copies libcod4_1_8x.so, dev.py no longer generates its loadPlugin
line, and scripts/server.sh no longer requires the plugin file.

37 test tools no longer copy/link or load libcod. The generic fixture runner
checks process mappings before accepting a pass, so a forgotten plugin cannot
silently satisfy the migrated APIs. Download and FPS regression runners accept
an exact script release as well as a candidate executable.

~~~sh
docker compose run --rm --no-deps --entrypoint make build \
  -C /workspace/cod4x-server DEBUG=true TARGETNAME=cod4x18_native_helpers -j4
~~~

Header-only changes require rebuilding the affected objects because the legacy
makefile does not track all header dependencies. This migration rebuilt the
registration object and changed implementations before linking.

Run a focused fixture from the repository root:

~~~sh
python3 dev-tools/tests/run-demo-viewing-24.py mp_killhouse \
  --binary /workspace/cod4x-server/bin/cod4x18_native_helpers \
  --scripts /absolute/path/to/release-scripts \
  --fixture dev-tools/tests/native-helpers.gsc \
  --completion-marker "NATIVE HELPERS COMPLETE"
~~~

For an existing deployment, remove only its libcod load directive when installing
the tested executable and matching scripts. Preserve configuration permissions
and all other settings. Retain the old executable, config and plugin privately
for rollback; never expose the config contents in logs. Retire the old plugin
from the active runtime after stopping that server.

## Development deployment

Deployment evidence and rollback locations are recorded in deployment.json and
deploy.py under the evidence directory above. The configuration backup is
private and must not be printed or committed.
