# Map-list route overview

The panel provides route overview; it does not show map type tags or numerical
difficulty ratings. The existing preview, author, release date,
voting permissions and red X remain available. The in-game navigation button
is labeled Voting and retains its existing action and shortcut.

## Behavior

The map-list information panel shows up to ten route names in two columns of
five. There are no route page controls. The heading reports the full count;
above ten it explicitly says that the first ten are shown. Names longer than
18 display characters end in an ellipsis to keep them inside their column.

Routes come from the existing database tables, not a map-specific list:
routes joins checkpoints and mapids. The alpha view includes normal routes
with a non-retired start and matching non-retired finish on the same map.
Private editor drafts, retired entries and bonus/secret routes are excluded.
A legacy normal anchor on Bouncer Training has no separate finish and is not
an extra route; its easy and hard routes remain visible.

The catalogue loads at map initialization. Successful checkpoint activation
refreshes it automatically after publishing, including shared-section network
routes that use the same activation path. Already-open map lists refresh too.
Request versions stop an older database reply replacing a newer snapshot.
Temporary SQL errors retain the last valid snapshot; an unavailable initial
snapshot and a genuinely empty route list have different messages.

CoD4 menu expressions support dynamic alpha but not dynamic RGB. The menu uses
twelve fixed palette colors selected from each route's stored RGB value. All
current alpha route colors have exact entries; arbitrary custom shades use the
nearest palette color. The original RGB data remains unchanged.

## Implementation

- server-gsc/opencj/maproutes.gsc: query, cache, display limits and palette.
- server-gsc/opencj/maps.gsc: catalogue initialization.
- server-gsc/opencj/checkpointpublish.gsc: automatic activation refresh.
- server-gsc/opencj/menus/maplist.gsc: selection/clearing and route fields.
- client-mod/cod4/ui_mp/scriptmenus/opencj_maplist.menu: ten route rows.
- client-mod/cod4/ui_mp/scriptmenus/opencj_ingame.menu: Voting button label.
- No database migration or production checkpoint modifications.
