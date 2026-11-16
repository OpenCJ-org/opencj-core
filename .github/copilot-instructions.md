# OpenCJ repository instructions

Core contains client-mod, server-gsc, server-ext, server-db, discord-integration
and dev-tools. cod4x-server and libcod are separate pinned engine submodules.

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

The coding-guideline draft remains INACTIVE. Do not enforce it, install global
loaders, or begin the proposed 2026 cleanup without separate explicit approval.
This repository instruction file does not activate that draft.

Never publish credentials, player data, local operator instructions, test
outputs, private recovery refs or stashes. Publication requires the completed
audit and the user's authorization; do not use mirror-push.
