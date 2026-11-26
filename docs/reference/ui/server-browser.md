# Server browser

The Escape menu's **Servers** button opens a list of OpenCJ servers that share
this server's database: up to ten rows with name, location, map and players.
Select a row and press **Join**; **Refresh** reads the list again.

## How servers appear

Each server keeps one row in `gameServers` (migration 031) up to date:

- It writes the row at map start, then every 60 seconds, and at most every
  10 seconds after players join or leave. The write is the same each time, so a
  lost reply needs no recovery.
- The browser lists rows refreshed in the last 180 seconds. A stopped or crashed
  server therefore drops out within three minutes without any cleanup.
- A server with a join password (`g_password`) keeps its row but marks it
  unlisted; it never appears in any browser.
- A server only publishes when it has both `opencj_server_id` (setup passes the
  instance name, for example `main-eu`) and `opencj_server_address`. Setup sets
  the address from the server's DNS name and game port; a server without a DNS
  name can still browse but is not listed.
- `opencj_server_location` is the optional location text asked by setup.

Servers with their own database do not see each other.

## Safety

Rows come from other servers, so the browsing server checks them before use:
addresses may only contain letters, digits, `.`, `-` and `:` (rows with anything
else are not offered), and quotes, backslashes, semicolons and line breaks are
removed from shown text. Pressing Join sends the client a `connect` command only
for the selected, already validated row; the client never builds a command itself.
The current server is marked "(this server)" and is not joined again.

## Load

One small row write per server per minute, plus at most one per 10 seconds while
players join or leave, and one bounded read (ten rows) when someone opens or
refreshes the browser.

## Implementation

- `server-gsc/opencj/serverlist.gsc`: publishing, reading, validation and join.
- `client-mod/cod4/ui_mp/scriptmenus/opencj_servers.menu`: the popup; it needs a
  matching compiled `mod.ff`.
- `server-db/migrations/031-game-servers.sql` and the gameplay grant in
  `server-db/tools/runtime_access.py`.
- Test: `dev-tools/tests/server-list.gsc` (focused GSC fixtures).

