# Map preview assets

The map browser uses bundled `loadscreen_<mapname>` materials and a separate
missing-image fallback. See the [asset guide](../../client-mod/assets/map-previews/README.md)
for source images, provenance and generation.

Capture instructions depend on the operator's game client and capture tool.
Keep machine-specific bindings, installation paths, session settings and
capture logs in private operating instructions.

For a new capture, use a game-only capture surface and preserve the player's
settings and session. Prepare asset/build work before taking control, keep the
capture phase brief, and release control immediately afterwards. If game-only
observation cannot be established, let the player supply the capture.

Use the actual map image; record the source, crop and conversion in asset
provenance. Generate matching images/materials, inspect the compiled output,
and follow the [client deployment procedure](../operations/client-assets.md).
