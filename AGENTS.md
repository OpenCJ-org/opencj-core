# OpenCJ core working instructions

This repository contains the application components and two engine submodules.
Preserve uncommitted files, untracked files and stashes. Never apply a stash as a
side effect of setup, migration or cleanup. Commit related core changes together;
engine changes need their own commit and an explicit core gitlink update.

Read operator-specific instructions, if present, from the path returned by
`git rev-parse --git-path info/opencj-local.md` before environment, deployment,
or computer-control work. They are private local instructions, not publication
content. Component AGENTS.md files and the linked runbooks also apply.

Read the native/script deployment runbook before changing native interfaces used
by GSC. Read the map capture runbook before game control. Do not operate on other
services or assume source changes are safe to deploy with an older binary.

Publication: push only reviewed branches and intended tags. Never use `push
--mirror` or publish `refs/local-only/*`, stashes, local operator instructions,
private evidence, credentials, database contents or migration recovery archives.
