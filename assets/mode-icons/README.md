# Stacked mode badges

Build on the source host with:

FPS badges render at 24:20; modifiers at 16:20. The square 512-pixel IWI
textures deliberately pre-compensate for those display ratios. Do not draw
all seven materials in square slots or stretch the lettering independently.
Colors: Classic blue (restricted), Standard neutral (baseline), Hax/Ele/Any%/HB
amber (expanded rules), TAS violet (assisted). Color supplements the labels.

Consumers audited:
- Run HUD: 24x20 FPS; 16x20 modifiers; existing five-unit gaps. Full row 108 units. Horizontal placement uses
  `left`, so artwork scales uniformly with menu UI on widescreen; `fullscreen`
  would widen the textures and lettering independently of their height. The row
  starts at x=128, reserving space for the route/progress statistics at x=6,
  including longer checkpoint counts. All five badges end at x=236.
- TAB scoreboard: 1.2 x icon height for FPS; 0.8 x height for modifiers. Fits
  between RPG and points columns, including at its existing 20-unit icon height.
  Its existing Any% progress text remains text.
- Challenges: 18x15 FPS; 12x15 modifiers; one-unit gaps. Counts preceding FPS
  badges for each dynamic row. Maximum 3 FPS + 4 modifiers ends at x=446,
  before the points column at x=448.
- Leaderboard/runsboard: passive FPS entry badges draw at 12x10 (6:5).
  Modifier column badges are centered at 12x15 in existing 15-unit cells,
  with floating offsets in `rect` rather than the integer-evaluated `origin`.
  Filters live in a shared toolbar with Allowed/Excluded labels and
  cyan/neutral fills. The FPS popup uses text for category names and values;
  clicking outside closes it without changing the selection.
- Main Escape menu and FPS dropdown contain no mode materials to widen.

Lucide 0.468.0 source references are in source/mode-icons. Its ISC attribution
ships in licenses/lucide.txt in the IWD, alongside existing license entries.

## Optional Oldschool badge

The approved amber bunny + OS badge is exported separately for future use:

`oldschool/` contains the 16:20 PNG, standalone transparent rabbit SVG/PNG,
pre-scaled game TGA/IWI, attribution and hashes. `oldschool-bunny.zip` bundles
those exports. The optional renderer also uses CairoSVG. This does not add a
mode, change the live seven-badge build, or register a material in mod.csv.
