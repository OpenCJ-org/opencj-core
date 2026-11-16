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
| `dev-tools/` | Development setup, tests and documentation |
| `cod4x-server/` | Pinned CoD4 engine submodule |
| `libcod/` | Pinned CoD2 engine extension submodule |

## Start here

Read the [development guide](dev-tools/README.md),
[documentation index](dev-tools/docs/index.md) and
[test guide](dev-tools/docs/testing.md).
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

The default project license is [AGPL-3.0](LICENSE). The Discord bridge retains
its [GPL-3.0 license](discord-integration/LICENSE). Component and third-party
asset notices continue to apply; the root license does not replace them.
Dev-tools is licensed under [AGPL-3.0](dev-tools/LICENSE).

The [coding guidelines](dev-tools/docs/proposals/code-readability-guidelines.md)
are an **inactive draft**. Their presence here does not activate them.
