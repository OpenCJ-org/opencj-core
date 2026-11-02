# Spike: injected overlays and movement automation

Date: 2026-10-05
Status: feasibility and source inspection complete; runtime detection unqualified.

## Decision

OpenCJ cannot reliably exclude every movement overlay or automation tool using
server-side observation alone. A rendering-only aid can produce the same network
messages as an unaided client; automation can produce otherwise legal inputs.
The server cannot infer the origin of identical messages.

There is nevertheless a useful first step without an OpenCJ-specific client:
qualify the module-reporting and screenshot features already present in CoD4x,
and add command-level evidence for movement analysis. This assumes players use a
compatible ordinary CoD4x client; it does not promise these features for vanilla
CoD4 1.7. Existing client cooperation is still client-side detection.

Do not commission a full custom client before measuring this existing path. If
the requirement remains strong admission control against injected tools, plan
for a required continuously running companion or a maintained CoD4x client
extension. Neither makes an owner-controlled PC provably cheat-free.

## Verified source findings

Paths below are relative to the repository root, with inspection-time line numbers.

| Finding | Evidence | Consequence |
| --- | --- | --- |
| CoD4x exposes getmodules and getss commands. | cod4x-server/src/sv_cmds.c:2234, :2283 | Try the existing client before building another one. |
| Module requests and screenshots delegate through optional backend callbacks. | cod4x-server/src/sapi.c:855, :861; backend loading around :761 | Command existence does not establish that the deployed backend/client returns usable results. |
| A module report carries a path and a long checksum, then emits OnModuleLoaded. | cod4x-server/src/sv_screenshot.c:180; cod4x-server/plugins/callback_declarations.h:53 | There is a server-plugin integration point. This wrapper does not itself implement a DLL denylist or prove report completeness. |
| The inspected XAC loader immediately returns. | cod4x-server/src/xac_helper.c:267 | XAC symbols in this tree are not evidence that this loader supplies active anti-cheat. |
| Pure mode is described as preventing modified IWD files. | cod4x-server/src/sv_main.c:3133 | Keep asset consistency checks, but do not describe sv_pure as a runtime DLL blocker. |
| OpenCJ receives each processed user command through an existing native hook. | cod4x-server/src/sv_client.c:1092; cod4x-server/src/opencj_main.cpp:650 | Reuse this point for evidence logging; inspect earlier processing if a rule must reject a command before simulation. |
| Both reported com_maxfps and command-time-derived FPS feed existing FPS logic. | server-gsc/opencj/fps.gsc:91; server-gsc/opencj/events/fpschange.gsc:3, :15; server-ext/opencj_fps.cpp:34 | Neither is proof of untampered rendering or human input. Record both with provenance instead of treating a successful registration as anti-cheat certification. |
| Current run demos sample at 20 Hz. | server-gsc/DEMOS.md:39; server-gsc/opencj/demorecording.gsc | Useful review evidence, but not a complete received-command trace and not a recording of a player's actual screen. |
| Existing cheating.gsc primarily tracks OpenCJ assistance/state such as noclip and pause. | server-gsc/opencj/cheating.gsc | Its name must not be mistaken for an external-cheat detector. |

An incidental source issue affects the getmodules all path:
BuildModuleRequests advances cl through the whole array and then logs cl->name
after the loop. That is a one-past-the-array read. Use individual player slots in
the initial lab and fix/review the all path before automating it.

Active runtime settings, deployed backend version and report behavior were not
verified. Defaults and setup-document examples are not live configuration facts.

## What each measure can establish

| Measure | Useful result | Limit |
| --- | --- | --- |
| Pure assets, cheats disabled, compatible client policy | Reject ordinary asset/configuration mismatches and keep the supported protocol consistent. | No general runtime integrity proof. A version string is not attestation. |
| Existing module reports | Potentially identify known tools that the reporting implementation exposes. | A clean list cannot prove absence. Hidden code and falsified or incomplete reports remain outside its guarantee. |
| Existing screenshots | Evidence when an unwanted overlay is actually captured. | Rendering/capture paths can omit overlays; the client supplies the image. Blank or missing images are not proof of guilt. |
| Server movement/state validation | Reject concrete invalid actions, protocol violations or run transitions under server rules. | Legal automated inputs and guidance-only overlays may look legitimate. |
| Command-level statistical review | Find repeated suspicious timing/turn/input patterns. | Skilled players, valid binds, FPS switches and network conditions can resemble automation. No universal human-versus-bot threshold is established. |
| Companion process | Add ongoing file/module/runtime checks while keeping the supported game executable. | Extra client software, maintenance, compatibility and tampering exposure remain. |
| Custom CoD4x client/extension | Integrate integrity checks and admission enforcement more closely. | Considerable ongoing engineering; still no guarantee against every software or hardware aid. |

Strafe guidance, collision and trajectory aids can use map geometry and local
state already needed to render and predict movement. Merely withholding extra
server messages does not remove that information. An automated movement trace
that is legal under the same physics is not an impossible-movement violation.

## Recommended first implementation

1. Qualify existing CoD4x reporting on an isolated test server and consenting test
   client. Identify the exact supported client and backend versions. Request
   modules for a single slot, observe OnModuleLoaded, and request one screenshot.
   Establish response timing, completeness signaling if any, and failure modes.
   The callback interface inspected here does not itself prove an end-of-list
   or fresh complete response.
2. Add a server plugin or native integration that records report provenance and
   recognizes confirmed prohibited modules. Use observed content fingerprints
   where available, not a filename-only rule. Determine the checksum algorithm
   and coverage before trusting it; the long field is not established as a
   cryptographic integrity measurement. Unknown modules start in review, since
   Windows, graphics drivers, recording tools and overlays vary legitimately.
3. Add a bounded ring buffer of received user commands and the corresponding
   server state. Include command time, server receive/processing time, view/input
   fields, origin/velocity, movement state, FPS report/estimate, run identity,
   map/rule version and explicit save/load/teleport/pause boundaries. Preserve
   raw command values before interpretation. Bound memory and offload disk work:
   this server is 32-bit and already budgets memory for demos.
4. Retain relevant evidence for candidate records and flagged incidents. Keep
   audit evidence separate from playback data that may truncate attempts or be
   removed by winner retention. Analysis must account for packet batching, loss,
   duplicates, reconnects, legitimate map mechanics and assistance categories.
   Do not infer actual rendering FPS solely from packet arrival spacing.
5. Separate enforcement outcomes: confirmed known prohibited tool or verified
   rule violation can reject participation/run eligibility with an explanation;
   uncertain behavior requests review; missing/broken telemetry is an
   unverifiable session, not an automatic cheating ban. If a future strict mode
   requires reporting, deny eligibility until it works without claiming guilt.
6. First run in observation mode. Promote only reproduced, high-confidence rules
   after testing clean clients and reviewing false positives. Define whether a
   confirmed finding disconnects the player, stops the run, or prevents record
   submission. Account bans need retained evidence and a review path.

This work can increase detection and deterrence with the existing CoD4x client.
It cannot honestly label every accepted session free of external assistance.

## Last resort: companion before full client fork

A proposed companion would verify supported game files at launch, keep checking
the game process during play, and report relevant module/code-integrity changes.
It should use authenticated, fresh, expiring messages tied to the game session
and player identity. The server must gate admission or record eligibility on
that session, and handle monitor loss explicitly. Launch-only checks leave the
rest of the session unexamined.

Freshness and authentication prevent simple replay or session confusion; they
do not prove that the monitor or game on a hostile PC is truthful. A signed
executable also does not automatically make its runtime reports trustworthy.
Do not put a universal embedded client secret forward as a security boundary.
A real design needs independent review of tampering, report forgery and session
binding before claiming strong admission control.

Consider a maintained CoD4x extension/fork only if companion-based inspection
cannot meet the measured goals. Integrate runtime checks, a supported module
policy, session signaling and signed updates. Account for graphics drivers,
Steam/Discord/recording overlays, accessibility tools, client updates and the
cost of operating detections over time. Define permitted functionality rather
than calling all non-game DLLs cheats.

Windows process mitigations may harden selected injection avenues after
compatibility testing. Microsoft's signature policy specifically admits
Microsoft/Store/WHQL categories; it is not a general switch for an arbitrary
OpenCJ publisher allowlist. Dynamic-code restrictions can also conflict with
legitimate executable-code changes. Do not propose blanket enabling as a
drop-in solution for this legacy client.

A kernel anti-cheat is not the recommended first project for OpenCJ. More
privilege raises engineering and support costs without guaranteeing that all
external guidance, device macros or capture-based assistance disappears.

## Qualification matrix and exit criteria

All tests belong to an isolated development environment; do not run unknown
injected software against the public game service.

- Clean supported clients: stock rendering, normal FPS categories/switches,
  common permitted recording/communication overlays, several driver versions.
- Controlled known prohibited tools supplied for this investigation: loaded
  before connection and during play; guidance-only and automated behavior.
- Reporting behavior: clean reports, no report, partial/late reports, reconnect,
  client/backend mismatch and empty/black screenshot.
- Movement evidence: valid advanced movement and binds, map teleports, RPG jumps,
  save/load, pause, allowed assistance modes, lag, packet loss and batching.
- Resource behavior: simultaneous clients, bounded RAM, disk retention, logger
  backpressure and no blocking I/O in the movement loop.

Record whether each tool is visible in modules and screenshots, detection delay,
coverage gaps, false positives, overhead and client compatibility. Do not invent
a catch rate without these observations.

Proceed with server-only integration if current tools are exposed sufficiently
for the agreed enforcement policy. Escalate to a client component only if the
measured gaps are unacceptable. If comprehensive exclusion of all assistance
remains mandatory, acknowledge that neither route supplies that guarantee.

## External references

These support the mechanisms and limitations; local source findings above were
independently inspected on the authoritative server.

- CoD4x server overview and client relationship:
  https://github.com/callofduty4x/CoD4x_Server
- Screenshot dispatch and module event:
  https://github.com/callofduty4x/CoD4x_Server/blob/master/src/sv_screenshot.c
- Optional screenshot/module backend callbacks:
  https://github.com/callofduty4x/CoD4x_Server/blob/master/src/sapi.c
- Pure-mode definition:
  https://github.com/callofduty4x/CoD4x_Server/blob/master/src/sv_main.c
- Microsoft binary signature policy:
  https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-process_mitigation_binary_signature_policy
- Microsoft process mitigations:
  https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessmitigationpolicy
- Collins et al., Anti-Cheat: Attacks and the Effectiveness of Client-Side
  Defences (2024): https://tomchothia.gitlab.io/Papers/AntiCheat2024.pdf
  Its experiments concern other games and are not a CoD4/OpenCJ detection test.
