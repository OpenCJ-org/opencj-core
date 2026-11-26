# Challenges, earned points and shop ownership

## Challenge catalogue

Definitions and eligibility live in
[`challenges.gsc`](../../../server-gsc/opencj/challenges.gsc).
Keep each `challengeKey` stable: completions refer to it permanently. A challenge
with no linked `routeID` remains visible but unavailable. Startup refreshes
catalogue metadata and backfills qualifying finalized runs. Removing a definition
deactivates it without deleting earned completions.

Maps and routes use stable database IDs. An already linked challenge keeps its
binding when the map or route is renamed; labels and route hints help bind an
unlinked definition. Catalogue entries alone do not approve a map for voting.

Competitive rank uses current active challenge values and cumulative tier point
thresholds, not stored player levels. Spendable currency is different:
`challengeCompletions.pointsAwarded` records the reward at first completion,
and shop balance subtracts actual purchase prices. Later repricing or
deactivation does not remove earned currency or award the challenge again.

## Shop catalogue and transactions

The catalogue lives in [`shop.gsc`](../../../server-gsc/opencj/shop.gsc). Each item
names a registered cosmetic resource: a weapon loadout, an RPG or a player model.
Startup stores every sold item's price and availability for the purchase
procedure, and marks catalogue rows that are no longer sold as unavailable;
their owners keep them.

Every player owns the standard Desert Eagle, RPG-7 and default player model.
They are not stored as purchases; equipping one clears that equipment slot.
An item can also require a challenge rank and end its sale at a fixed time. The
server checks both before a purchase reaches SQL.

A preview gives the selected item for a few seconds while the player keeps
moving. A preview weapon receives the ammunition of the weapon it stands in for,
so it never adds firepower; saving is blocked until the preview ends. A player
model preview also shows a turning copy of the model in front of the player.

`shopBuyOrEquip` serializes requests per player, validates the current catalogue
and balance, and records ownership, paid price and equipment in one transaction.
Its unique ownership key prevents duplicate charges across servers. The native
MySQL wrapper drains stored-procedure results before reusing a connection.

Equipment is keyed by base weapon, or `player` for player models, independently
of display category. Owned items survive repricing or retirement. Catalogue slot
changes and equipped slots stay consistent.

## Schema and maintenance

Use the complete [setup/migration procedure](../../operations/database.md),
rather than applying isolated feature migrations from old notes.
Migrations 009–011 introduce the challenge/shop structures; 020–023 preserve
their references, historical ownership and awarded currency. Historical amounts
not recorded before migration 023 cannot be reconstructed exactly; see
[earned currency](../../operations/database.md#earned-currency-023).

Disable awarded challenge definitions and purchased items instead of deleting
them. Keep real account, award and purchase data out of public fixtures.
