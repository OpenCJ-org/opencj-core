OpenCJ Oldschool bunny badge
Approved concept: 16 November 2026. Amber rabbit with the OS label.

oldschool-badge.png: 512 x 640 RGBA artwork, correct 16:20 display ratio.
oldschool-symbol.svg / .png: standalone amber rabbit, transparent background.
opencj_icon_oldschool.tga / .iwi: 512 x 512 pre-scaled game texture.
Draw the game texture at 16 x 20 HUD units (or another 4:5 rectangle).
Do not draw the square texture at a square display size.
The IWI includes all ten mip levels. Lucide 0.468.0, ISC; see LICENSE-lucide.txt.

Prepared for later integration; not registered in mod.csv or any live mode.
Integration will need the matching material and appropriate UI/HUD slot.
Regenerate on the source host with the existing image-venv Python:
  source/build_mode_icons.py --oldschool-only
Dependencies: Pillow, CairoSVG, DejaVuSans-Bold.ttf.
