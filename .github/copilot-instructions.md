# OpenCJ repository instructions

Core contains client-mod, server-gsc, server-ext, server-db, discord-integration
and dev-tools. cod4x-server and libcod are separate pinned engine submodules.

Before adding, moving or expanding files or entries, read the active
[file placement and privacy rule](instructions/repository-content.instructions.md).
It covers folder choice, public/private content and Git tracking.

When setting or bumping `VERSION`, follow the [release notes rule](instructions/release-notes.instructions.md).

Also follow the active [audit maintenance rules](instructions/audit-maintenance.instructions.md)
to preserve privacy, licensing, fresh-install support, tool portability and current
documentation, test organization and discovery.
Extend the relevant maintenance rule when completing another audit step.

Read [development setup](../docs/setup/development.md) and the
[test guide](../docs/development/testing.md) for the affected work.
Keep related core changes reviewable together. Engine edits require a separate
engine commit and an explicit core gitlink update.

Preserve existing uncommitted work, untracked files and stashes. Do not apply a
stash as a side effect of setup or cleanup. Do not initialize optional nested
engine submodules recursively.

Before changing native interfaces called by GSC, read the
[native/script deployment procedure](../docs/operations/native-scripts.md).
Use private local operator instructions, if present, before environment,
deployment or game-control work. Their location is returned by
`git rev-parse --git-path info/opencj-local.md`.
Do not infer installation paths or deployment permission from public examples.

Follow the active [coding guidelines](../dev-tools/agent-guidelines/coding-guidelines.md)
for first-party code in every component and both engines. They apply across
languages, including scripts, tests, SQL and hand-authored menu definitions.
Preserve published history during the approved 2026 cleanup; use focused new
commits and keep behavior fixes distinct from mechanical layout changes.

Never publish credentials, player data, local operator instructions, test
outputs, private recovery refs or stashes. Publication requires the completed
audit and the user's authorization; do not use mirror-push.
