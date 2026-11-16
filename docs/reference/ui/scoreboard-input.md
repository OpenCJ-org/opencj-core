# Scoreboard input and silent aliases

The startup menu installs the Tab hold/release aliases from
[`opencj_scoreboard_setup.inc`](../../../client-mod/cod4/ui_mp/scriptmenus/opencj_scoreboard_setup.inc).
The down alias sets OpenCJ's held/active state and installs the release binding;
the up alias clears that state and restores the down binding. Key-down uses
`vstr` rather than opening the stock scoreboard directly.

Use unquoted dvar identifiers in `setDvar` and preserve the binding's escaped
quotes through both the asset linker and client command parser. Source text
alone does not prove that the compiled menu retains the intended tokens.
Parser addresses observed in a particular client build are private investigation
evidence, not portable API identifiers.

The [client-init check](../../../dev-tools/tests/check_client_init_menu.py)
reads unlinked compiled menus and checks command tokenization, preserved state
and duplicate-startup behavior. Supply its explicit input directory; it does
not control a game client. Hold/release behavior also needs an in-game check
when the binding mechanism changes. Follow the
[client-asset procedure](../../operations/client-assets.md) for build/deployment.
