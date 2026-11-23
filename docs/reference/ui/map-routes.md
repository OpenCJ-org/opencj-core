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
routes joins checkpoints and mapids. The overview includes named normal routes
with at least one non-retired finish on the same map. Private editor drafts,
routes without an active finish, and bonus/secret routes are excluded.

The catalogue loads at map initialization. Successful checkpoint activation
refreshes it automatically after publishing, including shared-section network
routes that use the same activation path. Already-open map lists refresh too.
A newer refresh cancels obsolete queued reads in a level-owned scope. Running
reads retain the SQL adapter's execution/socket limits and discard their results
when they settle; cancellation does not interrupt the active MySQL call. Request
versions also reject replies that completed just before cancellation. The shared
snapshot does not belong to one player's menu, so closing a menu does not cancel
a refresh needed by other players. The queue deadline remains ten seconds.
Temporary SQL errors retain the last valid snapshot; an unavailable initial
snapshot and a genuinely empty route list have different messages.

CoD4 menu expressions support dynamic alpha but not dynamic RGB. The menu uses
twelve fixed palette colors selected from each route's stored RGB value. All
colors matching those entries use their corresponding slots; arbitrary custom
shades use the nearest palette color. The original RGB data remains unchanged.

## Implementation

- server-gsc/opencj/maproutes.gsc: query, cache, display limits and palette.
- server-gsc/opencj/maps.gsc: catalogue initialization.
- server-gsc/opencj/checkpointpublish.gsc: automatic activation refresh.
- server-gsc/opencj/menus/maplist.gsc: selection/clearing and route fields.
- client-mod/cod4/ui_mp/scriptmenus/opencj_maplist.menu: ten route rows.
- client-mod/cod4/ui_mp/scriptmenus/opencj_ingame.menu: Voting button label.
- No database migration or production checkpoint modifications.
