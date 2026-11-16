# Competitive overview: podium trophies

silver, gold and bronze trophies connected by one
podium. Gold is raised in the center. The outer canvas is transparent; there
is no enclosing button border, background plate, gradient, or hover shading.

`competitive.svg` is the editable master. `competitive.png` is the final RGBA
export.
Only this selected design belongs in the final asset library.

Rebuild from the client-mod directory:

    python3 source/build_competitive_icon.py

The generator preserves manual SVG edits, renders at 4x resolution, and writes
a 512 x 256 PNG, TGA, and full RGBA IWI mip chain. The game uses the existing
`opencj_competitive` material. One 78 x 46 click area contains the 64 x 32
artwork and the single `Top 10` label. All three trophies activate the same tab.
