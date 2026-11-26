# Scoreboard input and silent aliases

The startup menu installs the Tab hold/release aliases from
[`opencj_scoreboard_setup.inc`](../../../client-mod/cod4/ui_mp/scriptmenus/opencj_scoreboard_setup.inc).
The down alias sets OpenCJ's held/active state and installs the release binding;
the up alias clears that state and restores the idle binding. Key-down uses
`vstr` rather than opening the stock scoreboard directly.

Binds are saved in the shared player profile and apply on every server, so the
idle binding is `vstr opencj_sb_tab`, built from two archived dvars with fixed
text. Each press first points `opencj_sb_next` at the stock fallback
(`bind TAB +scores; +scores`), then runs `opencj_sb_mod`. OpenCJ sets that
unarchived dvar on connect to select the custom board instead. After a game
restart it no longer exists, so on another server the first press shows the
stock board and leaves Tab bound to `+scores`. Leaving OpenCJ without the exit
button and joining another server without a restart still keeps the custom
binding. Running a mod-only cfg on each press would also catch that case, but
the client prints an `execing` line for every press.

While the board is open, its scroll input menu counts as an open menu. HUDs the
board does not cover (bottom HUDs, minimap, position HUD) stay visible: menu
HUDs allow `opencj_scoreboard_input`, and
[`scoreboard.gsc`](../../../server-gsc/opencj/scoreboard.gsc) clears
`hideWhenInMenu` on the matching script HUD elements until the board closes.

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
