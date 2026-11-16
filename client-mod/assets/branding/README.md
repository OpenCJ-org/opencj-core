# OpenCJ branding icon

`opencj-logo-clean.png` is a conservative built-in ImageGen edit of the existing
blue-gray jumping soldier/RPG icon. It removes white fringing and accidental
interior holes, smooths the edges, and adds a thin dark outline. Pose, weapon,
orientation and overall color palette are retained. The background is transparent.
The edit prompt and hashes are recorded in `opencj-logo-clean.json`.

`source/build_logo.py` converts this source to the existing 1024x1024 TGA and
DXT5 IWI, preserving the prior flags, mip offsets and encoded byte length. Run
with the Python environment with Pillow, from the client-mod directory:

```sh
python3 \
  source/build_logo.py
```

Intentional branding continues to use `opencj_logo_nobg`. Missing map imagery
uses the separate question-mark material `opencj_missing_image`.
