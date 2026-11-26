# Beta weapon skins and player models

`source/build_beta_skins.py` generates the shop's Beta collection and the
player models into `cod4/`:

- the Glitch ("Neon Corrupt") skin for the Desert Eagle and the RPG, with the
  RPG's rockets and the shop icons;
- the dark default player model and the black Beta player model with a beta
  mark on its backpack, with matching heads and first-person hands;
- a trimmed `weapons/mp/deserteagle_mp` that lets player models supply the hands.

Run it on a machine with the game and Mod Tools; it prints a SHA-256 manifest of
every file it writes:

```sh
python3 -B source/build_beta_skins.py --game-main GAME/main \
    --stock-raw MOD_TOOLS/raw --stock-deagle UNLINKED/weapons/mp/deserteagle_mp
```

`--stock-raw` needs the stock xmodel, xmodelsurfs, xmodelparts, materials and
material_properties named in the script. `--stock-deagle` is the stock
Desert Eagle weapon file exported from the game's fastfiles, for example with
the OpenAssetTools Unlinker. Add `--preview-dir` for PNG copies of the textures.

## Provenance and licensing

These outputs are derived from Call of Duty 4 stock assets: recoloured stock
textures, stock materials, models and weapon files with renamed references,
and stock body meshes with new texture coordinates for the backpack mark. The
stock inputs come from the user's licensed game and the CoD4 Mod Tools and are
not stored in this repository.

Their terms come from the end user license agreement shipped with the Call of
Duty 4 Mod Tools ("Release of Map Tools to the Public"), reviewed in November 2026.
It is not legal advice; in summary:

- Material made with the tools ("New Game Materials") may be shared with other
  players only free of charge and never commercially. Shop items cost earned
  challenge points, never money; keep it that way.
- It must work only with the retail Call of Duty 4, not as a stand-alone product.
- Activision owns it as a derivative work and may use published copies. The
  derived files in `cod4/` are therefore not covered by the project's AGPL
  license; `build_beta_skins.py` itself is OpenCJ code.
- Published material must show, in any online description and for a reasonable
  time on its opening screen, the creator's name and e-mail address and the words
  "THIS MATERIAL IS NOT MADE OR SUPPORTED BY ACTIVISION." The repository notice is
  [NOTICE-ACTIVISION.md](../../NOTICE-ACTIVISION.md); the mod's opening screen and
  the website do not show it.
- The stock Desert Eagle weapon file is exported from the game's fastfiles rather
  than taken from the Mod Tools, so it falls under the game's own license.

## Mesh notes

- The Desert Eagle's grip, slide and barrel texture areas are shared by both
  sides of the gun, mirrored, so lettering would read backwards on one side.
- In first person the RPG tube passes the camera. Its triangles are found from
  the mesh and painted from their 3D position (`TubeStripes`), so the neon lines
  run straight along the tube whatever the texture layout.
- The body texture's back is mirrored across the spine, so the backpack pieces
  get new texture coordinates in the map's unused lower half (`BackpackMark`).
- DXT1 rounds near-black greys towards green; player textures are snapped to
  grey levels it stores exactly (`dxt1_neutral`).
