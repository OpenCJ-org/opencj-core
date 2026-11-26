# Activision material in the client mod

THIS MATERIAL IS NOT MADE OR SUPPORTED BY ACTIVISION.

OpenCJ's own code and artwork are licensed under the [AGPL](LICENSE). Some files
in `cod4/` are not: they are copied from, generated with or derived from the Call
of Duty 4 Mod Tools or the game, and are "New Game Materials" under the Mod Tools
end user license agreement. Activision and its licensors own them; the AGPL does
not apply to them. They include:

- files copied unchanged from the Mod Tools' `raw` folder, mainly in
  `material_properties/`, `materials/`, `soundaliases/`, `ui_mp/` and `xmodelparts/`;
- weapon files in `weapons/mp/`, which are stock weapon files or edits of them;
- everything `source/build_beta_skins.py` writes: the Beta weapon skins, the
  player models, their materials, models, meshes, textures and shop icons (see
  [assets/beta-skins](assets/beta-skins/README.md));
- the compiled `mod.ff` and `z_opencj.iwd` built from these files.

Under that agreement this material may only be shared free of charge, never for
commercial purposes, and only for use with the retail Call of Duty 4: Modern
Warfare. Activision may use published New Game Materials for any purpose.

Third-party material with its own license is listed in `cod4/licenses/`.
