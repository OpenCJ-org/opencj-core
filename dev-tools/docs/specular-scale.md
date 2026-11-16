# Map-controlled specular strength (#201)

Issue: https://github.com/OpenCJ-dev/server-gsc/issues/201

## Behavior

The native server registers `r_specularColorScale` with default `1` and the
client's existing range `0..100`. `SV_InitGameVM` resets it before map scripts
run, including `map_restart`. Existing map scripts can still call `setDvar` to
choose their strength; fractional values are supported. A map without an
override gets `1`, independent of the previous map.

The `CVAR_CONFIG` flag uses the existing codinfo replication path. Updated
values are included in game state for joining clients and published to current
clients by `SV_PreFrame`. No per-player polling or new client asset is needed.
The client retains its cheat-protection flag; cheats remain disabled.

The existing Specular **Off / Map / On** choices are unchanged. They control
`r_specular` and `r_specularMap`, separately from this map-owned strength.
Off disables specular; Map uses the original materials; On uses white masks.

Implementation: `cod4x-server/src/sv_game.c`. No GSC map edits or database writes.
