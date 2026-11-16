---
applyTo: "**"
---

# Preserve the open-source audit requirements

This is an active maintenance rule for OpenCJ work, including engine changes
made alongside core changes. It does not activate the 13 coding guidelines or
authorize the proposed 2026 code cleanup.

Keep the requirements below true when changing the affected files. Run checks
appropriate to the change and report any unverified part. Do not repeat the
whole audit for an unrelated edit or treat a previous pass as proof that a new
change works.

## Public content and Git history

Follow [file placement, privacy and licensing](repository-content.instructions.md)
for every new file and entry. Keep reusable information public and installation
details, raw evidence and recovery material private. Use the established folders;
do not turn public guides into session diaries.

Before committing, review the staged diff, new files and commit metadata for
personal paths, personal contact details, secrets and private operational data.
Keep the approved contributor identity. Ignoring a file does not remove a
tracked or historical copy.

Before publishing, inspect the exact outgoing commits and refs, not only the
current tree. Recheck imported or merged history for private material, including
old upstream credentials. Do not publish recovery refs or stashes, or use a
mirror push. If private material entered the outgoing history, stop publication
of that material and preserve a private recovery copy before remediation.
Do not rewrite already published history as a routine cleanup.

For submodule updates, confirm the pinned commit is available from the intended
remote before publishing its parent. Preserve the compatible pin; a remote's
default branch is not a substitute for the pinned revision.

## Licenses and source records

Apply the licensing section of the file-placement rule when adding, updating or
packaging third-party material. Keep source, version/hash and applicable notices
with the source and distributed output. Verify packaging retains required
notices. Preserve recorded uncertainties; do not silently invent permissions or
treat an earlier audit as clearance for a new asset or dependency.

## Fresh installation and upgrades

Setup and runtime changes must account for a checkout with no private files,
database contents, previous build outputs or personal tool installation.
Document external prerequisites and provide configurable inputs. Keep private
configuration private; generate credentials rather than embedding working ones.

Setup must preserve existing configuration, data and uncommitted work.
Database bootstrap must reject nonempty or partially initialized databases
instead of silently overwriting them. Upgrades must use the versioned migration
path. Keep runtime database permissions limited to the required operations.

When changing setup, migrations, build prerequisites or startup, exercise the
affected path in a disposable installation. Select a separate Compose project,
database volume and port; a new project name alone does not isolate an explicitly
named external volume. Use synthetic data and authorized external game assets.
Check relevant repeat-run preservation and cleanup behavior. State which parts
were actually tested; container startup alone is not an in-game or client-build
pass.

## Portable tools and tests

Use the selected installation's configuration to resolve containers, networks,
volumes and mounted assets. Do not assume a maintainer's container name, personal
path, particular CPU numbers or an output left by an earlier investigation.
New database test runners should use `dev-tools/tests/compose_environment.py`
when targeting the Compose test installation. Do not add a silent fallback to
another running database. Set an engine fixture's working directory explicitly
when a library or input is resolved relative to it; do not rely on a previous
normal-server launch to prepare shared runtime files.

Validate required inputs before starting expensive work or creating fixtures.
Accept explicit paths for historical binaries, dumps and operator inputs, and
document how they are obtained. Keep special historical checks clearly separate
from ordinary regression claims; do not silently skip missing inputs and report
a full pass. Respect supported resource requirements and validate explicit CPU
selections against available cores.

Use isolated resources and reviewed synthetic fixtures. Do not test destructive
operations against live data. Remove only the resources created by that run,
including temporary accounts and secrets, on success or failure. Keep generated
outputs and raw logs ignored and private.

When changing environment selection, test a nondefault installation as well as
missing or invalid prerequisites. Record each suite's command, dependencies and
effects in the [test guide](../../docs/development/testing.md). Unit-test success
does not establish engine, database, asset or performance success.

## Completing further audit steps

When finishing another audit step, add or refine the reusable requirement in
the appropriate active instruction file and link it from the shared agent entry
point. Include the check that will detect regressions and the changes that
require that check. Update current public documentation, while keeping the
step's raw results and personal decisions in private records.

Record unfinished work honestly. These maintenance rules reduce regressions;
they do not replace review when dependencies, deployment methods or project
requirements change.
