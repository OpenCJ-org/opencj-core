# Repository layout

Core contains the client assets, scripts, native extensions, database, Discord
bridge and development tools. The engines are pinned submodules: cod4x-server
for CoD4, and libcod for CoD2. Their relative position preserves the existing
server-ext build relationship.

## Documentation and instructions

- `docs/setup/`: installation and first-run guides.
- `docs/reference/`: current behavior and interfaces, grouped by component.
- `docs/development/`: build, testing and investigation methods.
- `docs/operations/`: reusable backup and deployment procedures.
- `docs/decisions/`: accepted technical decisions and their reasons.
- `docs/proposals/`: designs that are not implemented.
- `docs/research/`: exploratory findings, explicitly separate from decisions.
- `.github/`: Copilot instructions and GitHub workflow configuration.
- `dev-tools/agent-guidelines/drafts/`: inactive guideline drafts.

Use one maintained page for each procedure or behavior. Component READMEs should
point to it; avoid separate manuals that must be edited in parallel. See the
[documentation index](../README.md#which-pages-describe-current-behavior) for
current-reference versus decision/proposal/research status.

Personal host instructions, deployment records, backup inventories, raw test
outputs and recovery archives are private operating material, not project
documentation. Paths and accounts belong in local configuration.

## Engine revisions and history

Initialize only the engine needed for the target. Do not initialize optional
nested submodules recursively. Commit engine changes in their own repository,
then update the core gitlink. A fresh checkout must be able to fetch the recorded
engine commit.

Use `git log --first-parent` for integration history and
`git log --follow -- <path>` for a file's history across directory moves.
Publication history is reviewed separately from the current working tree.
