# OpenCJ core

OpenCJ's client assets, game scripts, native extensions, database migrations,
Discord bridge and development tools live in one repository. Component directories
retain their own build and runtime responsibilities.

| Directory | Purpose |
| --- | --- |
| `client-mod/` | CoD2/CoD4 client assets and asset source |
| `server-gsc/` | Game scripts and map patches |
| `server-ext/` | OpenCJ native extensions |
| `server-db/` | Schema, migrations and database administration tools |
| `discord-integration/` | Optional Discord bridge |
| `dev-tools/` | Development setup and tests |
| `docs/` | Setup, reference, development and operations guides |
| `.github/` | Agent instructions and GitHub workflows |
| `cod4x-server/` | Pinned CoD4 engine submodule |
| `libcod/` | Pinned CoD2 engine extension submodule |

## Start here

The first release target is **beta-0.1.0**. Use `sudo bash opencj.sh install` for the interactive
[server installer](docs/setup/server.md), including separate instances, shared
databases and an optional independently supplied website.

Read the [development guide](dev-tools/README.md),
[documentation index](docs/README.md) and
[test guide](docs/development/testing.md).
The base game, Windows Mod Tools and installed maps are external prerequisites;
they are not supplied by this repository.

Initialize the engine needed for your target:

```sh
git submodule update --init -- cod4x-server
# Only when developing CoD2:
git submodule update --init -- libcod
```

Do not initialize engine submodules recursively: the inherited CoD4 fork contains
optional legacy gitlinks without complete mappings. CoD4 builds use the engine
and `server-ext/`; the separate `libcod/` checkout is for CoD2.

A core commit pins the expected engine revisions. Existing modified engine
checkouts are preserved by the development helper. To change an engine, commit
there first, then commit its updated gitlink in core. Do not use `--remote` as a
routine setup step: it bypasses the recorded revision.

## History and licensing

Component history predates the unified checkout. Use `git log --follow -- <path>`
when following files across directory moves. Current-tree cleanup and publication
history review are separate steps; neither implies that private historical
content is cleared for release.

The default project license is [AGPL-3.0](LICENSE). The Discord bridge retains
its [GPL-3.0 license](discord-integration/LICENSE). Component and third-party
asset notices continue to apply; the root license does not replace them.
Dev-tools is licensed under [AGPL-3.0](dev-tools/LICENSE).
See [licenses and asset sources](docs/reference/licensing.md) for retained
notices, external inputs and unresolved redistribution questions.

The [coding guidelines](dev-tools/agent-guidelines/coding-guidelines.md)
are **active** for all first-party OpenCJ code, including tests and tools.
