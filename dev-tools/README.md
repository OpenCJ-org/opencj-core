# OpenCJ development tools

These tools belong to `opencj-core`; do not clone the former component
repositories as siblings. Build and test on a Linux development host. Windows
CoD4 Mod Tools is required separately for client fastfiles.

Start with [getting started](docs/getting-started.md), then the
[test guide](docs/testing.md). Browse the [documentation index](docs/index.md)
for current component behavior, operating procedures and unresolved proposals.

The supported database bootstrap creates the complete recorded schema only in
an empty development database. Existing databases follow the migration and
backup procedure; initialization never overwrites them. Proprietary game assets,
map binaries, private configuration and player data are not included.

## Everyday development

Open `opencj.code-workspace` over Remote SSH. Core components share one Git
history; CoD4 and CoD2 engines appear as separate submodule repositories.

From this directory:

```sh
python3 dev.py check
python3 dev.py build
python3 dev.py up
python3 dev.py logs
```

## Optional tools

The Discord bridge uses the Compose `discord` profile and a private config file
under `local/`. See [its configuration format](../discord-integration/README.md).

Manual backups, runtime permissions and upgrades are covered in
[database safety](docs/database-safety.md). No automatic backups, game-client
control, or coding-guideline activation happens during setup.

## Local records

Keep credentials, captures, dumps, deployment evidence and machine-specific
notes under ignored `local/`. Read private operator instructions when present.
The [coding guidelines](docs/proposals/code-readability-guidelines.md) remain an
**inactive draft**. Original migration recovery refs and stashes are local-only.
