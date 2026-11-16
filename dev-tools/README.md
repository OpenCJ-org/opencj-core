# OpenCJ development tools

These tools belong to `opencj-core`; do not clone the former component
repositories as siblings. Build and test on a Linux development host. Windows
CoD4 Mod Tools is required separately for client fastfiles.

Start with [getting started](../docs/setup/development.md), then the
[test guide](../docs/development/testing.md). Browse the [documentation index](../docs/README.md)
for current component behavior, operating procedures and unresolved proposals.

The supported database bootstrap creates the complete recorded schema only in
an empty development database. Existing databases follow the migration and
backup procedure; initialization never overwrites them. Proprietary game assets,
map binaries, private configuration and player data are not included.

## Everyday development

Open `opencj.code-workspace` in the configured Linux development environment. Core components share one Git
history; CoD4 and CoD2 engines appear as separate submodule repositories.

From this directory:

```sh
python3 dev.py check
python3 dev.py build
python3 dev.py up
python3 dev.py logs
```

`build` stops the development server and performs a clean engine build. For a
running installation, follow the [native/script deployment runbook](../docs/operations/native-scripts.md)
and build a separate executable before a guarded deployment. The legacy engine
makefile does not track all header dependencies.

Current CoD4 helpers are built directly from `server-ext`; the standalone libcod
submodule is for CoD2. See [native helpers](../docs/reference/native/helpers.md).
Client assets need a separate Windows build and verified deployment;
[matching files on disk alone may not prevent a download](../docs/operations/client-assets.md).

## Tests

From the core root, run `python3 -B dev-tools/scripts/test.py portable`.
Use `python3 -B dev-tools/scripts/test.py list` to find the current integration
suites and their explicit prerequisites. See the [test guide](../docs/development/testing.md).

## Optional tools

The Discord bridge uses the Compose `discord` profile and a private config file
under `local/`. See [its configuration format](../discord-integration/README.md).

Artwork scripts use the dependencies in `requirements-art.txt`.
Read [licenses and asset sources](../docs/reference/licensing.md) before
redistributing their inputs, outputs or tools. They require
licensed map/game inputs supplied by the operator. See the
[preview asset guide](../docs/development/map-previews.md).

Manual backups, runtime permissions and upgrades are covered in
[database safety](../docs/operations/database.md). No automatic backups, game-client
control, or coding-guideline activation happens during setup.

## Local records

Keep credentials, captures, dumps, deployment evidence and machine-specific
notes under ignored `local/`. Read private operator instructions when present.
The [coding guidelines](agent-guidelines/coding-guidelines.md) are **active**.
Personal setup and recovery records remain private.
