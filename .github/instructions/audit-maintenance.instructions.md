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

## Current documentation and historical records

When changing behavior, interfaces, commands, configuration, schema or test
prerequisites, review the affected current documentation in the same change.
Verify statements against the relevant source and supported command arguments.
Update or remove contradicted text in place; do not append a newer paragraph
while leaving an older instruction that says the opposite.

Use one maintained page for each procedure or behavior. Keep component READMEs
as navigation when a guide already exists. Before replacing a duplicate manual,
preserve its unique current guidance in the right reference or operations page
and update its incoming links. Migration files and Git history already record
implementation chronology; current guides should not become feature changelogs.

Keep reusable accepted decisions, proposals and research in their established
folders with explicit status and assumptions. Do not treat a proposal, research
recommendation or old investigation as implementation approval. A superseded
decision must point to its replacement and leave the normal setup path. Retain
compatibility requirements and useful reasons; age alone does not make them
obsolete. Do not invent acceptance or measured results to fill a gap.

Keep installation inventories, observed row counts, deployment receipts,
one-off benchmarks, raw logs and personal investigation timelines private.
Extract reusable findings with their scope and limits. An old result or the
presence of a test is not evidence that the current code passes. Mark actual
tool limitations and unfinished work instead of documenting an intended future
capability as if it exists.

After moving or editing documentation, check local links, heading anchors and
referenced source paths, and search for duplicate or superseded instructions.
Check changed CLI examples against the parser or safe `--help` output; do not
execute write/deployment procedures merely to proofread them. Report source
review separately from builds, integration tests and in-game verification.
Documentation-only edits do not require a server restart.

## Test organization and discovery

When adding, moving or changing tests, update the maintained
[test catalogue](../../dev-tools/tests/catalogue.json) with their purpose,
owning fixtures/helpers, command, prerequisites and effects. Every retained
executable group must have a usable entry point. Run the catalogue check and
the affected suites; CI and local portable testing must use the same command.

Keep automatic discovery restricted to reviewed offline entry points. A file
named `test_*.py` can open a database or replace a socket at import time; do not
recursively import unrelated integration scripts to discover tests. Adding a
portable entry requires checking its imports and effects. It must not depend
on a private configuration, running service, game asset or historical output.

Fix still-relevant tests when their schema, interfaces or setup change.
Use current synthetic fixtures and build probes from maintained source.
Remove obsolete one-off audits and completed before/after investigations from
the current tree; preserve required recovery material privately or in Git.
Do not merely rename them "legacy" or "unsupported" and leave them as clutter.
Keep tests for supported compatibility and real regressions; age alone is not
grounds for deletion. Check incoming references before removing a fixture.

A passing command must execute its intended checks. Treat zero discovered tests,
missing completion markers, failed subprocesses and skipped required checks as
incomplete or failing, never as a full pass. Report the scope actually exercised.

Test harnesses must own their temporary sockets, accounts, schemas, containers
and outputs. Use unique temporary resources and clean them on failure as well as
success. Forwarding observation hooks belong only in the fixture's source copy.
Test-only and documentation changes do not justify restarting a live server.

## Completing further audit steps

When finishing another audit step, add or refine the reusable requirement in
the appropriate active instruction file and link it from the shared agent entry
point. Include the check that will detect regressions and the changes that
require that check. Update current public documentation, while keeping the
step's raw results and personal decisions in private records.

Record unfinished work honestly. These maintenance rules reduce regressions;
they do not replace review when dependencies, deployment methods or project
requirements change.
