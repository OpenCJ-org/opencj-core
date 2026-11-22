"""Render approved stacked mode badges in logical HUD proportions.

Textures remain power-of-two squares; drawing is pre-scaled so rendering at
24x20 (FPS) or 16x20 (modifiers) restores normal-width type and glyphs.
Ele, split-route and bot geometry derives from Lucide 0.468.0 (ISC license);
the Oldschool rabbit and Tutorial graduation cap are Lucide 0.468.0 SVGs.
Tutorial runs show their badge in the FPS slot, since the server picks their FPS.
"""

from pathlib import Path
import hashlib
import io
import json
import math
import struct
import sys
import zipfile
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
S = 32
FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'
COLORS = {
    'classic': '#80b8ff',
    'standard': '#d9e2e7',
    'expanded': '#efbb65',
    'assisted': '#c7a3ff',
    'tutorial': '#7fd18b',
}
# Badges whose glyph is a stock Lucide SVG, rasterized at source resolution.
SVG_GLYPHS = {'oldschool': 'rabbit.svg', 'fps_tutorial': 'graduation-cap.svg'}
# Compiled 2D icon material that new badge materials are cloned from.
MATERIAL_TEMPLATE = 'opencj_icon_fps_any'


def draw_svg_glyph(im, name, color, size, x, y):
    """Draw a badge's Lucide glyph, size units square, with its top left at x, y.

    Rasterizes the curves at source resolution before game-sized mipmaps are made.
    """
    import cairosvg

    source = (ROOT / 'source/mode-icons' / SVG_GLYPHS[name]).read_text()
    source = source.replace('currentColor', color).replace(
        'stroke-width="2"', 'stroke-width="2.2"'
    )
    raw = cairosvg.svg2png(
        bytestring=source.encode(),
        output_width=round(size * S),
        output_height=round(size * S),
    )
    glyph = Image.open(io.BytesIO(raw)).convert('RGBA')
    im.alpha_composite(glyph, (round(x * S), round(y * S)))


def badge(name, label, kind):
    fps = name.startswith('fps_')
    w = 24 if fps else 16
    im = Image.new('RGBA', (w * S, 20 * S))
    d = ImageDraw.Draw(im)
    color = COLORS[kind]
    d.rounded_rectangle((0, 0, w * S - 1, 20 * S - 1), radius=int(0.8 * S), fill='#26313b')
    d.rectangle((0, 0, w * S - 1, int(0.8 * S) - 1), fill=color)

    def text(value, x, y, size, fill):
        font = ImageFont.truetype(FONT, round(size * S))
        while d.textlength(value, font=font) > (w - 1.7) * S:
            font = ImageFont.truetype(FONT, font.size - 1)
        d.text((x * S, y * S), value, font=font, fill=fill, anchor='mm')

    if fps and name in SVG_GLYPHS:
        # A mode that replaces the FPS category shows its glyph instead of "FPS".
        glyph_size = 10.5
        draw_svg_glyph(im, name, color, glyph_size, (w - glyph_size) / 2, 1.9)
        text(label, w / 2, 15.6, 4.6, '#edf2f5')
    elif fps:
        text('FPS', w / 2, 6.3, 5.3, color)
        text(label, w / 2, 15.6, 4.6, '#edf2f5')
    else:
        text(label, w / 2, 15.9, 4.5, '#edf2f5')
        scale = 11.5 / 24
        ox = (w - 11.5) / 2
        oy = 1.9

        def xy(x, y):
            return ((ox + x * scale) * S, (oy + y * scale) * S)

        stroke = round(2.2 * scale * S)

        def line(points):
            pts = [xy(*p) for p in points]
            d.line(pts, fill=color, width=stroke, joint='curve')
            for x, y in pts:
                d.ellipse(
                    (x - stroke / 2, y - stroke / 2, x + stroke / 2, y + stroke / 2), fill=color
                )

        if name == 'ele':
            line([(18, 9), (12, 3), (6, 9)])
            line([(12, 3), (12, 17)])
            line([(5, 21), (19, 21)])
        elif name == 'anypct':
            line([(16, 3), (21, 3), (21, 8)])
            line([(8, 3), (3, 3), (3, 8)])
            arc = [
                (
                    8 + 4 * math.cos(-math.pi / 4 * i / 12),
                    13.7 + 4 * math.sin(-math.pi / 4 * i / 12),
                )
                for i in range(13)
            ]
            line([(12, 22), (12, 13.7)] + arc + [(3, 3)])
            line([(15, 9), (21, 3)])
        elif name == 'tas':
            line([(12, 8), (12, 4), (8, 4)])
            a = xy(4, 8)
            b = xy(20, 20)
            d.rounded_rectangle((*a, *b), radius=2 * scale * S, outline=color, width=stroke)
            for p in [
                [(2, 14), (4, 14)],
                [(20, 14), (22, 14)],
                [(15, 13), (15, 15)],
                [(9, 13), (9, 15)],
            ]:
                line(p)
        elif name in SVG_GLYPHS:
            # Keep the approved Lucide silhouette at the modifier glyph size.
            draw_svg_glyph(im, name, color, 11.5, ox, oy)
        elif name == 'halfbeat':
            # Equal-height, side-by-side keys, with a clear gap at small sizes.
            for letter, x in [('A', 1.2), ('D', 8.4)]:
                d.rounded_rectangle(
                    (x * S, 4 * S, (x + 6.4) * S, 11.5 * S),
                    radius=0.65 * S,
                    outline=color,
                    width=round(0.6 * S),
                )
                text(letter, x + 3.2, 7.8, 4.8, color)
    return im


def iwi(im):
    levels = [im]
    while levels[-1].width > 1:
        p = levels[-1]
        levels.append(p.resize((p.width // 2, p.height // 2), Image.Resampling.LANCZOS))
    encoded = [p.tobytes('raw', 'BGRA') for p in levels]
    return (
        b'IWi'
        + bytes([6, 1, 0])
        + struct.pack('<HHH', im.width, im.height, 1)
        + struct.pack('<4I', *[28 + sum(map(len, encoded[i:])) for i in range(4)])
        + b''.join(reversed(encoded))
    )


def register_material(name):
    """Create the badge's compiled material, mod.csv entry and GDT source if missing.

    The material is cloned from MATERIAL_TEMPLATE: the same 2D, 512x512 icon
    material with only its name and texture name changed. String pointers after
    the names move by the change in name length (as in build_notification_glow).
    """
    material = 'opencj_icon_' + name
    material_path = ROOT / 'cod4/materials' / material
    if not material_path.exists():
        old = MATERIAL_TEMPLATE.encode('ascii')
        data = bytearray((ROOT / 'cod4/materials' / MATERIAL_TEMPLATE).read_bytes())
        for offset, expected in [(0, old), (4, old), (64, b'colorMap'), (72, old)]:
            pointer = struct.unpack_from('<I', data, offset)[0]
            if data[pointer:].split(b'\0', 1)[0] != expected:
                raise SystemExit('Unexpected template material layout at offset ' + str(offset))
        if data[76:79] != b'2d\0':
            raise SystemExit('Template material is not a 2D material')
        delta = len(material) - len(old)
        for offset in (4, 72):
            struct.pack_into('<I', data, offset, struct.unpack_from('<I', data, offset)[0] + delta)
        struct.pack_into('<I', data, 64, struct.unpack_from('<I', data, 64)[0] + 2 * delta)
        material_path.write_bytes(bytes(data).replace(old, material.encode('ascii')))

    csv = ROOT / 'cod4/mod.csv'
    entry = 'material,' + material
    lines = csv.read_text().splitlines()
    if entry not in lines:
        template_index = lines.index('material,' + MATERIAL_TEMPLATE)
        lines.insert(template_index + 1, entry)
        csv.write_text('\n'.join(lines) + '\n')

    gdt = ROOT / 'source/cod4/source_data/opencj_icons.gdt'
    text = gdt.read_text()
    header = '\t"' + material + '" ( "material.gdf" )\n'
    if header not in text:
        template_header = '\t"' + MATERIAL_TEMPLATE + '" ( "material.gdf" )\n'
        start = text.index(template_header)
        end = text.index('\n\t}\n', start) + len('\n\t}\n')
        block = text[start:end].replace(MATERIAL_TEMPLATE, material)
        gdt.write_text(text[:end] + block + text[end:])


def main():
    output = ROOT / 'assets/mode-icons'
    output.mkdir(parents=True, exist_ok=True)
    manifest = {
        'logical_dimensions': {'fps': [24, 20], 'modifier': [16, 20]},
        'glyphs': 'Lucide 0.468.0 (Tutorial: graduation-cap); Halfbeat original A/D keycaps',
        'icons': {},
    }
    sheet = Image.new('RGBA', (1100, 240), '#171f26')
    d = ImageDraw.Draw(sheet)
    for i, (name, label, kind) in enumerate(
        [
            ('fps_classic', 'Classic', 'classic'),
            ('fps_standard', 'Standard', 'standard'),
            ('fps_any', 'Hax', 'expanded'),
            ('fps_tutorial', 'Tutorial', 'tutorial'),
            ('ele', 'ELE', 'expanded'),
            ('anypct', 'ANY%', 'expanded'),
            ('halfbeat', 'HB', 'expanded'),
            ('tas', 'TAS', 'assisted'),
        ]
    ):
        logical = badge(name, label, kind)
        logical.save(output / (name + '.png'))
        texture = logical.resize((512, 512), Image.Resampling.LANCZOS)
        texture.save(ROOT / 'source/texture_source' / ('opencj_icon_' + name + '.tga'))
        raw = iwi(texture)
        target = ROOT / 'cod4/images' / ('opencj_icon_' + name + '.iwi')
        target.write_bytes(raw)
        register_material(name)
        manifest['icons'][name] = {
            'label': label,
            'role': kind,
            'sha256': hashlib.sha256(raw).hexdigest(),
            'bytes': len(raw),
        }
        width = 24 if name.startswith('fps_') else 16
        large = logical.resize((width * 4, 80), Image.Resampling.LANCZOS)
        sheet.alpha_composite(large, (i * 136 + 10, 20))
        small = logical.resize((width * 2, 40), Image.Resampling.LANCZOS)
        sheet.alpha_composite(small, (i * 136 + 10, 120))
    sheet.save(output / 'contact-sheet.png')
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('Built eight mode badges; FPS 24x20, modifiers 16x20.')


def export_oldschool():
    """Export the approved optional badge without changing the seven live modes."""
    import cairosvg

    output = ROOT / 'assets/mode-icons/oldschool'
    output.mkdir(parents=True, exist_ok=True)
    logical = badge('oldschool', 'OS', 'expanded')
    logical.save(output / 'oldschool-badge.png')
    texture = logical.resize((512, 512), Image.Resampling.LANCZOS)
    texture.save(output / 'opencj_icon_oldschool.tga')
    (output / 'opencj_icon_oldschool.iwi').write_bytes(iwi(texture))
    source = (ROOT / 'source/mode-icons/rabbit.svg').read_text()
    source = source.replace('currentColor', COLORS['expanded']).replace(
        'stroke-width="2"', 'stroke-width="2.2"'
    )
    (output / 'oldschool-symbol.svg').write_text(source)
    cairosvg.svg2png(
        bytestring=source.encode(),
        output_width=512,
        output_height=512,
        write_to=str(output / 'oldschool-symbol.png'),
    )
    (output / 'LICENSE-lucide.txt').write_bytes((ROOT / 'cod4/licenses/lucide.txt').read_bytes())
    (output / 'README.txt').write_text("""OpenCJ Oldschool bunny badge
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
""")
    paths = sorted(p for p in output.iterdir() if p.is_file() and p.name != 'manifest.json')
    manifest = {
        'mode': 'oldschool',
        'label': 'OS',
        'logical_dimensions': [16, 20],
        'glyph_source': 'https://github.com/lucide-icons/lucide/blob/0.468.0/icons/rabbit.svg',
        'files': {
            p.name: {
                'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
                'bytes': p.stat().st_size,
            }
            for p in paths
        },
    }
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    bundle = ROOT / 'assets/mode-icons/oldschool-bunny.zip'
    with zipfile.ZipFile(bundle, 'w', zipfile.ZIP_DEFLATED) as z:
        for p in sorted(output.iterdir()):
            if p.is_file():
                z.write(p, p.name)
    print('Exported Oldschool bunny badge and reusable symbol: ' + str(bundle))


if __name__ == '__main__':
    if sys.argv[1:] == ['--oldschool-only']:
        export_oldschool()
    elif not sys.argv[1:]:
        main()
    else:
        raise SystemExit('Usage: build_mode_icons.py [--oldschool-only]')
