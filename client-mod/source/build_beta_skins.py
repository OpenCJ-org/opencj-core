"""Build the Beta collection and the player models as client assets.

The Beta collection is the Glitch skin ("Neon Corrupt": black chrome with glowing
neon glitch bands) for both the Desert Eagle and the RPG, plus a near-black player model with a beta mark on its
backpack. A dark grey player model is everyone's default.

Weapon skins repaint the stock colour map while keeping its shading, wear and
dark details. Their models (rockets included), materials and weapon files are
clones of the stock assets that differ only in names, so the skins share the stock
meshes, animations and gameplay values. Each item also gets a shop icon: weapon
icons recolour the stock icon, and the player model's is rendered from its mesh.

Player models recolour the body, helmet, headset, gloves and first-person hands.
Weapons let the player model replace their hands, so the gloves always match.

Stock inputs are read from the user's licensed game and Mod Tools files and are
not stored in the repository:

    --game-main     directory holding the stock iw_*.iwd archives
    --stock-raw     Mod Tools raw folder (xmodel, xmodelsurfs, xmodelparts,
                    materials and material_properties of the assets named below)
    --stock-deagle  the stock weapons/mp/deserteagle_mp weapon file
    --preview-dir   optional folder for PNG review copies

The RPG skins clone OpenCJ's own weapons/mp/rpg_mp. Weapon files must be linked
into mod.ff through weapon entries in mod.csv; the server did not load them as
loose files from the IWD.

Requires Pillow with DDS DXT encoding and the DejaVu fonts.
"""

import argparse
import hashlib
import io
import math
import random
import struct
import zipfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageOps, ImageStat

from iwi_texture import IWI_FORMAT_DXT1, IWI_FORMAT_DXT5, encode_iwi, mipmaps

CLIENT_ROOT = Path(__file__).resolve().parents[1]
COD4 = CLIENT_ROOT / "cod4"
OPENCJ_RPG_WEAPON = COD4 / "weapons" / "mp" / "rpg_mp"

DDS_HEADER_BYTES = 128
DDS_FOURCC_OFFSET = 84
IWI_FORMAT_OFFSET = 4
IWI_FLAGS_OFFSET = 5
IWI_SIZE_OFFSET = 6
IWI_FILE_SIZES_OFFSET = 12
DXT_BLOCK_BYTES = {IWI_FORMAT_DXT1: 8, IWI_FORMAT_DXT5: 16}
DXT_FOURCC = {IWI_FORMAT_DXT1: b"DXT1", IWI_FORMAT_DXT5: b"DXT5"}

# String pointers in the stock material layouts, measured from the Mod Tools files.
# Model materials (phong): name, reference image, technique set, then the name/image
# pairs of three texture slots and the names of two constants.
MODEL_MATERIAL_POINTERS = (0x00, 0x04, 0x34, 0x40, 0x48, 0x4C, 0x54, 0x58, 0x60, 0x64, 0x78)
MODEL_SPECULAR_POINTER = 0x60
# 2D icon materials: name, reference image, technique set (twice) and one texture slot.
ICON_MATERIAL_POINTERS = (0x00, 0x04, 0x34, 0x3C, 0x40, 0x48)
# Both the Mod Tools linker and the server's BG_LoadWeaponDefInternal reject weapon
# files longer than 0x27FF bytes (cod4x-server/src/asmsource/_bg_weapons_load_obj.asm).
MAX_WEAPON_FILE_BYTES = 0x27FF
# Linking these makes the linker pull stock .rmb graphs that Mod Tools does not
# ship. They only drive gamepad vibration, so the skins leave them unset.
GAMEPAD_RUMBLE_KEYS = {"fireRumble", "meleeImpactRumble"}

WEAPON_MAP_PX = 1024
SPECULAR_SIZE_PX = 512
# Stock pixels this dark are holes, bores and internals that every skin keeps.
DARK_DETAIL_LUMINANCE = 38
# Multiplying by stock luminance and doubling keeps mid-grey steel at paint value.
SHADING_GAIN = 2
# Icons are painted from a patch this many times their size, so patterns stay legible.
ICON_PATTERN_SCALE = 2
ICON_PATTERN_TOP = 600
ICON_PAINT_LIFT = (40, 42, 48)
ICON_PIXELS_PER_BAND = 600
ICON_MEAN_LIGHT = 90

FONT_DIRECTORY = Path("/usr/share/fonts/truetype/dejavu")


def font(name, size_px):
    return ImageFont.truetype(str(FONT_DIRECTORY / name), size_px)


# Stock texture decoding ------------------------------------------------------


def read_stock_image(game_main, image_name):
    """Return the IWI bytes of a stock image from the game's own archives."""
    entry_name = f"images/{image_name}.iwi"
    for archive_path in sorted(game_main.glob("iw_*.iwd")):
        with zipfile.ZipFile(archive_path) as archive:
            if entry_name in archive.namelist():
                return archive.read(entry_name)
    raise FileNotFoundError(f"Stock image {entry_name} is not in {game_main}")


def decode_iwi(iwi_bytes):
    """Decode the full-size mip of a DXT1/DXT5 IWI and return it with its flags."""
    if iwi_bytes[:3] != b"IWi":
        raise ValueError("Not a CoD4 IWI texture")
    format_code = iwi_bytes[IWI_FORMAT_OFFSET]
    flags = iwi_bytes[IWI_FLAGS_OFFSET]
    if format_code not in DXT_BLOCK_BYTES:
        raise ValueError(f"Unsupported stock IWI format {format_code}")
    width, height = struct.unpack_from("<HH", iwi_bytes, IWI_SIZE_OFFSET)
    full_file_bytes = struct.unpack_from("<I", iwi_bytes, IWI_FILE_SIZES_OFFSET)[0]
    blocks_wide = max(1, (width + 3) // 4)
    blocks_high = max(1, (height + 3) // 4)
    top_mip_bytes = blocks_wide * blocks_high * DXT_BLOCK_BYTES[format_code]
    # Mips are stored smallest first, so the full-size mip ends the file.
    top_mip = iwi_bytes[full_file_bytes - top_mip_bytes : full_file_bytes]
    dds_header = struct.pack(
        "<4s7I44x", b"DDS ", 124, 0x1007, height, width, top_mip_bytes, 0, 1
    )
    dds_header += struct.pack("<2I4s5I", 32, 4, DXT_FOURCC[format_code], 0, 0, 0, 0, 0)
    dds_header += struct.pack("<5I", 0x1000, 0, 0, 0, 0)
    image = Image.open(io.BytesIO(dds_header + top_mip))
    image.load()
    return image.convert("RGBA"), flags


def encode_dxt_iwi(image, format_code, flags):
    """Encode every mip with Pillow's DDS writer and wrap the pixels as an IWI."""
    encoded_mips = []
    for mip_image in mipmaps(image.convert("RGBA")):
        output = io.BytesIO()
        mip_image.save(output, format="DDS", pixel_format=DXT_FOURCC[format_code].decode())
        dds = output.getvalue()
        if dds[DDS_FOURCC_OFFSET : DDS_FOURCC_OFFSET + 4] != DXT_FOURCC[format_code]:
            raise ValueError("The image encoder did not produce the requested DXT format")
        encoded_mips.append(dds[DDS_HEADER_BYTES:])
    return encode_iwi(image.width, image.height, encoded_mips, format_code, flags=flags)


# Material, model and weapon clones -------------------------------------------


def read_c_string(data, offset):
    end = data.index(b"\0", offset)
    return data[offset:end].decode("ascii")


def clone_material(template, renames, pointer_offsets):
    """Rebuild the material's string pool with renamed strings and patched pointers."""
    pointers = [struct.unpack_from("<I", template, offset)[0] for offset in pointer_offsets]
    pool_start = min(pointers)
    if pool_start <= max(pointer_offsets) or max(pointers) >= len(template):
        raise ValueError("Material template does not match the measured stock layout")
    strings_by_offset = {}
    offset = pool_start
    while offset < len(template):
        text = read_c_string(template, offset)
        strings_by_offset[offset] = text
        offset += len(text) + 1
    if any(pointer not in strings_by_offset for pointer in pointers):
        raise ValueError("Material pointer does not start a pooled string")
    missing = set(renames) - set(strings_by_offset.values())
    if missing:
        raise ValueError(f"Material template lacks strings: {sorted(missing)}")
    output = bytearray(template[:pool_start])
    new_offsets = {}
    for old_offset, text in strings_by_offset.items():
        new_offsets[old_offset] = len(output)
        output += renames.get(text, text).encode("ascii") + b"\0"
    for slot_offset, pointer in zip(pointer_offsets, pointers):
        struct.pack_into("<I", output, slot_offset, new_offsets[pointer])
    return bytes(output)


def clone_model(template, renames):
    """Rename strings in a raw xmodel; its strings are read sequentially.

    renames maps each old name to (new name, expected number of occurrences).
    """
    model = template
    for old, (new, expected) in renames.items():
        old_name = old.encode("ascii") + b"\0"
        found = template.count(old_name)
        if found != expected:
            raise ValueError(f"Expected {expected} references to {old}, found {found}")
        model = model.replace(old_name, new.encode("ascii") + b"\0")
    return model


def drop_empty_weapon_keys(weapon):
    """Remove empty keys, to fit the parser's limit, and the gamepad rumble keys."""
    header, *fields = weapon.split("\\")
    if header != "WEAPONFILE" or len(fields) % 2:
        raise ValueError("Stock weapon file is not a WEAPONFILE key/value list")
    kept = [header]
    for index in range(0, len(fields), 2):
        key = fields[index]
        value = fields[index + 1]
        if value == "" or key in GAMEPAD_RUMBLE_KEYS:
            continue
        kept.append(key)
        kept.append(value)
    return "\\".join(kept)


def set_weapon_key(weapon, key, value):
    header, *fields = weapon.split("\\")
    for index in range(0, len(fields), 2):
        if fields[index] == key:
            fields[index + 1] = value
            return "\\".join([header, *fields])
    return "\\".join([header, *fields, key, value])


def playable_weapon(weapon, name):
    """Fit the parser's limit and let the player model's hands replace the weapon's."""
    weapon = set_weapon_key(drop_empty_weapon_keys(weapon), "isHandModelOverridable", "1")
    if len(weapon) > MAX_WEAPON_FILE_BYTES:
        raise ValueError(f"{name} is {len(weapon)} bytes; the weapon parser "
                         f"accepts at most {MAX_WEAPON_FILE_BYTES}")
    return weapon


def clone_weapon(template, base, skin_assets):
    """Change only the models; ammo and handling stay as in the template."""
    weapon = template
    for key, stock_model, _ in base.models:
        old = f"\\{key}\\{stock_model}\\"
        if weapon.count(old) != 1:
            raise ValueError(f"Weapon template does not contain exactly one {old!r}")
        weapon = weapon.replace(old, f"\\{key}\\{skin_assets.model(stock_model)}\\")
    return playable_weapon(weapon, skin_assets.weapon)


# Surface masks and shading ---------------------------------------------------


class StockSurfaces:
    """A stock colour map split into steel, an optional grip panel and kept detail."""

    def __init__(self, stock_color, grip_outline=None, kept_areas=(), dark_detail=DARK_DETAIL_LUMINANCE,
                 stretch_shading=False):
        self.color = stock_color.convert("RGB")
        self.size = self.color.size
        stock_luminance = self.color.convert("L")
        # A dark stock finish would leave the paint nearly black, so its light is stretched.
        self.luminance = ImageOps.autocontrast(stock_luminance, cutoff=1) if stretch_shading else stock_luminance
        grip = Image.new("L", self.size, 0)
        if grip_outline:
            ImageDraw.Draw(grip).polygon(grip_outline, fill=255)
        self.grip_mask = grip.filter(ImageFilter.GaussianBlur(1.5))
        dark = stock_luminance.point(lambda value: 255 if value < dark_detail else 0)
        # A grip's dark grain is repainted rather than kept.
        keep = ImageChops.subtract(dark, grip).filter(ImageFilter.GaussianBlur(1))
        for area in kept_areas:
            area_mask = Image.new("L", self.size, 0)
            ImageDraw.Draw(area_mask).rectangle(area, fill=255)
            keep = ImageChops.lighter(keep, area_mask)
        self.keep_mask = keep

    def shade(self, paint):
        """Apply the stock light and wear to flat paint."""
        return shade_with(paint, self.luminance)

    def compose(self, steel_paint, grip_paint, glow=None, detail=None):
        """Shade the paint with the stock light; glow is added unshaded, so it reads as light.

        detail (white = all) says how much stock light, wear and kept detail to show. Where a
        part is magnified on screen, that detail would show as blotchy pixels instead.
        """
        luminance = self.luminance
        keep = self.keep_mask
        if detail is not None:
            luminance = Image.composite(luminance, Image.new("L", self.size, PLAIN_LIGHT), detail)
            keep = ImageChops.multiply(keep, detail)
        steel = shade_with(steel_paint, luminance)
        grip = shade_with(grip_paint, luminance)
        painted = Image.composite(grip, steel, self.grip_mask)
        if glow is not None:
            painted = ImageChops.add(painted, glow)
        return Image.composite(self.color, painted, keep)


# The even light given to parts that show no stock detail.
PLAIN_LIGHT = 120


def shade_with(paint, luminance):
    shading = Image.merge("RGB", (luminance, luminance, luminance))
    shaded = ImageChops.multiply(paint.convert("RGB"), shading)
    return shaded.point(lambda value: min(255, value * SHADING_GAIN))


# Weapon bases ----------------------------------------------------------------


class WeaponBase:
    """A stock weapon whose assets the skins clone, and where its parts sit in UV space."""

    def __init__(self, prefix, color_image, specular_image, material, models, icon, grip_outline=None,
                 grip_center=None, kept_areas=(), dark_detail=DARK_DETAIL_LUMINANCE,
                 stretch_shading=False, view_surfaces=None, has_tube=False):
        self.prefix = prefix
        self.color_image = color_image
        self.specular_image = specular_image
        self.material = material
        # (weapon file key, stock model, material slots in that model)
        self.models = models
        self.icon = icon
        # The view model's surfaces, when patterns should follow how much each area is
        # magnified on screen instead of having one size across the map.
        self.view_surfaces = view_surfaces
        # A launcher tube gets plain chrome and lengthwise neon (see TubeStripes).
        self.has_tube = has_tube
        self.grip_outline = grip_outline
        self.grip_center = grip_center
        self.kept_areas = kept_areas
        self.dark_detail = dark_detail
        self.stretch_shading = stretch_shading


DEAGLE = WeaponBase(
    prefix="deagle",
    color_image="weapon_desert_eagle_silver_col",
    specular_image="~weapon_desert_eagle_silver_s~0e95b0eb",
    material="mtl_weapon_desert_eagle_silver",
    models=[("gunModel", "viewmodel_desert_eagle", 3), ("worldModel", "weapon_desert_eagle_silver", 3)],
    icon="weapon_desert_eagle",
    # The brown wood-grain grip panel and the magazine, traced from the stock UV layout.
    grip_outline=[(460, 94), (708, 94), (708, 440), (494, 440)],
    grip_center=(600, 268),
    kept_areas=[(806, 150, 1000, 512)],
)

DEAGLE_VIEW_SURFACES = "viewmodel_desert_eagle1"

RPG = WeaponBase(
    prefix="rpg",
    color_image="weapon_rpg7_col",
    specular_image="~weapon_rpg7_spec-rgb&weapon_~06163c5b",
    material="mtl_weapon_rpg7",
    # The rocket on the launcher and the one in flight share the launcher's material.
    models=[("gunModel", "viewmodel_rpg7", 3), ("worldModel", "weapon_rpg7", 5),
            ("rocketModel", "viewmodel_rpg7_rocket", 1), ("projectileModel", "projectile_rpg7", 3)],
    icon="weapon_rpg7",
    # The RPG is dark blued steel: only its darkest pixels are holes and bores.
    dark_detail=16,
    stretch_shading=True,
    # The tube fills the lower right of the view from few texels, which magnifies patterns
    # about ten times more than the launcher's small parts.
    view_surfaces="viewmodel_rpg71",
    has_tube=True,
)


class SkinAssets:
    def __init__(self, base, slug):
        self.stem = f"opencj_{base.prefix}_beta_{slug}"
        self.color_image = f"{self.stem}_col"
        self.specular_image = f"{self.stem}_spec"
        self.material = f"mtl_{self.stem}"
        self.weapon = f"{base.prefix}_beta_{slug}_mp"
        self.icon = f"opencj_shop_{base.prefix}_beta_{slug}"

    def model(self, stock_model):
        """weapon_rpg7 becomes weapon_opencj_rpg_beta_glitch; a _rocket suffix is kept."""
        kind = stock_model.split("_", 1)[0]
        suffix = "_rocket" if stock_model.endswith("_rocket") else ""
        return f"{kind}_{self.stem}{suffix}"


# Painting helpers ------------------------------------------------------------


def flat(color, size):
    return Image.new("RGB", size, color)


def draw_text_in(image, area, text, font_name, color):
    """Centre one line of text in an area, shrinking it until it fits."""
    draw = ImageDraw.Draw(image)
    left, top, right, bottom = area
    size = int((bottom - top) * 0.7)
    text_font = font(font_name, size)
    while size > 8:
        text_font = font(font_name, size)
        box = draw.textbbox((0, 0), text, font=text_font)
        if box[2] - box[0] <= right - left - 12:
            break
        size -= 2
    box = draw.textbbox((0, 0), text, font=text_font)
    x = left + (right - left - (box[2] - box[0])) // 2 - box[0]
    y = top + (bottom - top - (box[3] - box[1])) // 2 - box[1]
    draw.text((x, y), text, font=text_font, fill=color)


def draw_beta(image, center, size_px, color, font_name="DejaVuSans-Bold.ttf"):
    ImageDraw.Draw(image).text(center, "β", font=font(font_name, size_px), fill=color, anchor="mm")


def smooth_noise(seed, cells, size):
    """Low-frequency grey noise: random cells scaled up with bicubic smoothing."""
    generator = random.Random(seed)
    cells_image = Image.new("L", (cells, cells))
    cells_image.putdata([generator.randrange(256) for _ in range(cells * cells)])
    return cells_image.resize(size, Image.Resampling.BICUBIC)


# The Glitch skin ---------------------------------------------------------------

# Cyan and magenta neon, with the odd white-hot band.
GLITCH_COLORS = [(8, 217, 214), (255, 46, 99), (8, 217, 214), (255, 46, 99), (235, 235, 235)]
BLACK_CHROME = (16, 17, 20)
GRIP_BLACK = (12, 13, 16)
GLOW_BLUR_PX = 6


class TubeStripes:
    """Plain black chrome and lengthwise neon lines for a launcher tube.

    In first person the RPG's tube runs past the camera, so whatever its texture holds
    is shown huge. Its triangles are found from the mesh (a cylinder around the x axis)
    and painted from their 3D position: thin, broken neon lines where the angle around the
    axis is near a stripe angle, plus a few small blocks. They run straight along the tube
    at an even width, whatever the texture layout, and match the pistol's glitch look.
    """

    # The tube passes right by the camera, so even a few degrees of it is wide on screen.
    STRIPE_ANGLES_DEGREES = (15, 55, 100, 140, 195, 235, 280, 325)
    STRIPE_HALF_WIDTH_DEGREES = 0.5
    # Each stripe is cut into segments along the tube; each segment is shown or not,
    # long or short, and sometimes knocked sideways, like a corrupted line.
    SEGMENT_UNITS = 2.2
    SEGMENT_SHOWN = 0.55
    SEGMENT_SHIFTED = 0.22
    SEGMENT_SHIFT_DEGREES = 2.5
    # Small glitch blocks in a grid over the tube: angle by length cells, a few filled.
    BLOCK_CELL_DEGREES = 9.0
    BLOCK_CELL_UNITS = 1.4
    BLOCK_CHANCE = 0.05
    BLOCK_DEGREES = 2.2
    BLOCK_UNITS = 0.35
    # Tube triangles: normals across the axis and facing out from it, at a radius from the
    # thin front tube up to the wider rear section, with corners at similar radii.
    MAX_AXIAL_NORMAL = 0.35
    MIN_RADIUS_RATIO = 0.7
    MAX_RADIUS_RATIO = 2.4
    MAX_CORNER_RADIUS_SPREAD = 0.15
    MIN_OUTWARD = 0.8
    # Only a faint glow: a wide one would swamp the tube at this distance.
    HALO_BLUR_PX = 1
    HALO_STRENGTH = 0.5

    def __init__(self, surfaces_data, map_px=WEAPON_MAP_PX):
        self.map_px = map_px
        surface = max(parse_surfaces(surfaces_data), key=lambda mesh: len(mesh.positions))
        self.axis, self.radius = self._fit_axis(surface)
        self.mask = Image.new("L", (map_px, map_px), 0)
        self.stripes = Image.new("RGB", (map_px, map_px))
        mask_pixels = self.mask.load()
        stripe_pixels = self.stripes.load()
        for a, b, c in surface.triangles:
            radii = [self._radius(surface, i) for i in (a, b, c)]
            if (all(self._on_tube(surface, i) for i in (a, b, c)) and
                    max(radii) - min(radii) <= self.MAX_CORNER_RADIUS_SPREAD * max(radii)):
                self._paint_triangle(surface, (a, b, c), mask_pixels, stripe_pixels)
        if not self.mask.getbbox():
            raise ValueError("No tube found on the RPG view model")
        # Close the hairline gaps between neighbouring triangles.
        self.mask = self.mask.filter(ImageFilter.MaxFilter(3))
        halo = self.stripes.filter(ImageFilter.GaussianBlur(self.HALO_BLUR_PX))
        halo = halo.point(lambda value: round(value * self.HALO_STRENGTH))
        self.glow = ImageChops.add(self.stripes, halo)

    @staticmethod
    def _chance(*keys):
        """A repeatable pseudo-random number in [0, 1) for these integer keys."""
        value = 2166136261
        for key in keys:
            value = ((value ^ (key & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF
        value ^= value >> 15
        value = (value * 2246822519) & 0xFFFFFFFF
        value ^= value >> 13
        return value / 2 ** 32

    def _neon_at(self, angle, length):
        """The neon colour at a point on the tube, or None."""
        for stripe, stripe_angle in enumerate(self.STRIPE_ANGLES_DEGREES):
            # Segments start at a different place on each stripe.
            position = length / self.SEGMENT_UNITS + self._chance(stripe, 7)
            segment = math.floor(position)
            if self._chance(stripe, segment, 1) >= self.SEGMENT_SHOWN:
                continue
            # Some segments end early, so lengths vary.
            if position - segment > 0.45 + 0.55 * self._chance(stripe, segment, 2):
                continue
            shift = 0.0
            if self._chance(stripe, segment, 3) < self.SEGMENT_SHIFTED:
                shift = self.SEGMENT_SHIFT_DEGREES * (1 if self._chance(stripe, segment, 4) < 0.5 else -1)
            offset = abs((angle - stripe_angle - shift + 180) % 360 - 180)
            if offset <= self.STRIPE_HALF_WIDTH_DEGREES:
                return GLITCH_COLORS[(stripe + segment) % 2] if self._chance(stripe, segment, 5) > 0.08 \
                    else (235, 235, 235)
        cell_angle = math.floor(angle / self.BLOCK_CELL_DEGREES)
        cell_length = math.floor(length / self.BLOCK_CELL_UNITS)
        if self._chance(cell_angle, cell_length, 9) < self.BLOCK_CHANCE:
            if (angle - cell_angle * self.BLOCK_CELL_DEGREES < self.BLOCK_DEGREES and
                    length - cell_length * self.BLOCK_CELL_UNITS < self.BLOCK_UNITS):
                return GLITCH_COLORS[int(self._chance(cell_angle, cell_length, 10) * 2)]
        return None

    @staticmethod
    def _fit_axis(surface):
        """The point (y, z) that side-facing normals pass through, and the tube's radius."""
        rows = []
        for (x, y, z), (nx, ny, nz) in zip(surface.positions, surface.normals):
            if abs(nx) < 0.1 and ny * ny + nz * nz > 0.9:
                rows.append((y, z, ny, nz))
        # Least squares for the point closest to every normal line p + t n in the y/z plane.
        a11 = a12 = a22 = b1 = b2 = 0.0
        for y, z, ny, nz in rows:
            length = math.sqrt(ny * ny + nz * nz)
            ny, nz = ny / length, nz / length
            # Projector onto the line's normal space: I - n n^T.
            p11, p12, p22 = 1 - ny * ny, -ny * nz, 1 - nz * nz
            a11 += p11
            a12 += p12
            a22 += p22
            b1 += p11 * y + p12 * z
            b2 += p12 * y + p22 * z
        determinant = a11 * a22 - a12 * a12
        centre = ((a22 * b1 - a12 * b2) / determinant, (a11 * b2 - a12 * b1) / determinant)
        radii = sorted(math.hypot(y - centre[0], z - centre[1]) for y, z, _, _ in rows)
        # The tube is the most common side-facing radius.
        best = max(radii, key=lambda r: sum(1 for other in radii if abs(other - r) < 0.15))
        return centre, best

    def _radius(self, surface, index):
        _, y, z = surface.positions[index]
        return math.hypot(y - self.axis[0], z - self.axis[1])

    def _on_tube(self, surface, index):
        _, y, z = surface.positions[index]
        nx, ny, nz = surface.normals[index]
        dy, dz = y - self.axis[0], z - self.axis[1]
        radius = math.hypot(dy, dz)
        if not self.MIN_RADIUS_RATIO * self.radius <= radius <= self.MAX_RADIUS_RATIO * self.radius:
            return False
        if abs(nx) > self.MAX_AXIAL_NORMAL:
            return False
        return (ny * dy + nz * dz) / max(radius, 1e-6) > self.MIN_OUTWARD

    def _paint_triangle(self, surface, corners, mask_pixels, stripe_pixels):
        uvs = [surface.uvs[i] for i in corners]
        points = [(u * self.map_px, v * self.map_px) for u, v in uvs]
        angles = []
        for i in corners:
            _, y, z = surface.positions[i]
            angles.append(math.degrees(math.atan2(z - self.axis[1], y - self.axis[0])))
        # Unwrap so the three angles are within half a turn of the first.
        angles = [angles[0]] + [a - 360 * round((a - angles[0]) / 360) for a in angles[1:]]
        lengths = [surface.positions[i][0] for i in corners]
        (ax, ay), (bx, by), (cx, cy) = points
        area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        if abs(area) < 1e-9:
            return
        for py in range(max(0, int(min(ay, by, cy))), min(self.map_px - 1, int(max(ay, by, cy)) + 1) + 1):
            sy = py + 0.5
            for px in range(max(0, int(min(ax, bx, cx))), min(self.map_px - 1, int(max(ax, bx, cx)) + 1) + 1):
                sx = px + 0.5
                w0 = ((bx - sx) * (cy - sy) - (by - sy) * (cx - sx)) / area
                w1 = ((cx - sx) * (ay - sy) - (cy - sy) * (ax - sx)) / area
                w2 = 1 - w0 - w1
                if w0 < -0.01 or w1 < -0.01 or w2 < -0.01:
                    continue
                mask_pixels[px, py] = 255
                angle = (w0 * angles[0] + w1 * angles[1] + w2 * angles[2]) % 360
                length = w0 * lengths[0] + w1 * lengths[1] + w2 * lengths[2]
                neon = self._neon_at(angle, length)
                if neon is not None:
                    stripe_pixels[px, py] = neon

    def apply(self, detail, glow):
        """Clear the tube of stock detail and random glitch, and add its own lines."""
        clear = ImageOps.invert(self.mask)
        detail = ImageChops.multiply(detail, clear) if detail is not None else clear
        glow = ImageChops.add(ImageChops.multiply(glow, Image.merge("RGB", (clear,) * 3)), self.glow)
        return detail, glow


class TexelScale:
    """How large patterns should be in each part of a colour map.

    Measured from a view model: where one texel covers more of the gun, patterns are
    drawn smaller (and more often), so they look the same size on screen as on the
    Desert Eagle.
    """

    CELLS = 16
    MIN_SCALE = 0.1

    def __init__(self, surfaces_data=None, reference_data=None, map_px=WEAPON_MAP_PX):
        self.map_px = map_px
        self.cells = None
        if surfaces_data is None:
            return
        sides = self._texel_sides(surfaces_data)
        reference = sorted(self._texel_sides(reference_data).values())
        reference_side = reference[len(reference) // 2]
        self.cells = {cell: min(1.0, max(self.MIN_SCALE, reference_side / side)) for cell, side in sides.items()}

    def _texel_sides(self, data):
        """World units per texel side, per cell of the map."""
        totals = {}
        for surface in parse_surfaces(data):
            for a, b, c in surface.triangles:
                p0, p1, p2 = (surface.positions[i] for i in (a, b, c))
                t0, t1, t2 = (surface.uvs[i] for i in (a, b, c))
                e1 = [p1[k] - p0[k] for k in range(3)]
                e2 = [p2[k] - p0[k] for k in range(3)]
                cross = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2],
                         e1[0] * e2[1] - e1[1] * e2[0])
                world_area = math.sqrt(sum(value * value for value in cross)) / 2
                texel_area = abs((t1[0] - t0[0]) * (t2[1] - t0[1]) -
                                 (t2[0] - t0[0]) * (t1[1] - t0[1])) / 2 * self.map_px * self.map_px
                if texel_area < 1:
                    continue
                cell = (int((t0[0] + t1[0] + t2[0]) / 3 % 1 * self.CELLS),
                        int((t0[1] + t1[1] + t2[1]) / 3 % 1 * self.CELLS))
                world, texels = totals.get(cell, (0.0, 0.0))
                totals[cell] = (world + world_area, texels + texel_area)
        return {cell: math.sqrt(world / texels) for cell, (world, texels) in totals.items()}

    def halo_mask(self, size):
        """White where patterns keep full size, darker where they shrink (with the square of
        the scale, so only strongly magnified parts lose their halo and stock detail)."""
        mask = Image.new("L", (self.CELLS, self.CELLS), 255)
        if self.cells is not None:
            for (cell_x, cell_y), scale in self.cells.items():
                mask.putpixel((cell_x, cell_y), round(255 * scale * scale))
        return mask.resize(size, Image.Resampling.BILINEAR)

    def at(self, x, y):
        if self.cells is None:
            return 1.0
        cell = (int(x * self.CELLS / self.map_px) % self.CELLS, int(y * self.CELLS / self.map_px) % self.CELLS)
        return self.cells.get(cell, 1.0)


# Elements per 64 x 64 texel area at full size; smaller elements come more often.
GLITCH_BANDS_PER_CELL = 40 / 256
GLITCH_BLOCKS_PER_CELL = 60 / 256


def paint_glitch(base, size, texel_scale):
    """Neon Corrupt: black chrome with neon glitch bands that glow as if lit from inside.

    Returns the steel and grip paint, and the glow to add unshaded.
    """
    steel = flat(BLACK_CHROME, size)
    glow = Image.new("RGB", size)
    draw = ImageDraw.Draw(glow)
    generator = random.Random(5)
    width, height = size
    cell_px = width // TexelScale.CELLS
    for cell_y in range(0, height, cell_px):
        for cell_x in range(0, width, cell_px):
            scale = texel_scale.at(cell_x, cell_y)
            # Elements cannot be thinner than a texel, so on magnified parts they are
            # added in proportion to their shrinking length, not their area.
            bands = GLITCH_BANDS_PER_CELL / scale
            blocks = GLITCH_BLOCKS_PER_CELL / scale
            while bands > 0:
                if bands >= 1 or generator.random() < bands:
                    top = cell_y + generator.randrange(cell_px)
                    left = cell_x + generator.randrange(cell_px) - round(200 * scale)
                    draw.rectangle((left, top, left + max(2, round(generator.randrange(80, 500) * scale)),
                                    top + max(1, round(generator.randrange(2, 7) * scale))),
                                   fill=generator.choice(GLITCH_COLORS))
                bands -= 1
            while blocks > 0:
                if blocks >= 1 or generator.random() < blocks:
                    x = cell_x + generator.randrange(cell_px)
                    y = cell_y + generator.randrange(cell_px)
                    block = max(1, round(generator.choice((4, 6, 10)) * scale))
                    draw.rectangle((x, y, x + block, y + block), fill=generator.choice(GLITCH_COLORS[:2]))
                blocks -= 1
    grip = flat(GRIP_BLACK, size)
    if base.grip_center:
        draw_grip_core(glow, base.grip_center)
    # A soft halo a few texels wide would swamp magnified parts, so it fades out there.
    halo = glow.filter(ImageFilter.GaussianBlur(GLOW_BLUR_PX))
    halo = ImageChops.multiply(halo, Image.merge("RGB", (texel_scale.halo_mask(size),) * 3))
    return steel, grip, ImageChops.add(glow, halo)


def draw_grip_core(glow, center):
    """A neon diamond with glitch slices. Both grip panels share one texture, mirrored, so
    the emblem is symmetric left to right; a beta here would read backwards on one side."""
    draw = ImageDraw.Draw(glow)
    x, y = center
    for radius, color, width in ((92, GLITCH_COLORS[0], 7), (58, GLITCH_COLORS[1], 5), (24, (235, 235, 235), 4)):
        draw.polygon([(x, y - radius), (x + radius * 3 // 4, y), (x, y + radius), (x - radius * 3 // 4, y)],
                     outline=color, width=width)
    for offset, color in ((-38, GLITCH_COLORS[1]), (0, (235, 235, 235)), (30, GLITCH_COLORS[0])):
        draw.rectangle((x - 110, y + offset, x + 110, y + offset + 3), fill=color)


class Skin:
    def __init__(self, slug, paint, shine, gloss, specular_tint=None):
        self.slug = slug
        self.paint = paint
        self.shine = shine
        self.gloss = gloss
        self.specular_tint = specular_tint


SKINS = [
    # Black chrome: strong, tight highlights.
    Skin("glitch", paint_glitch, shine=1.5, gloss=1.3),
]


def specular_map(skin, stock_specular):
    """Scale the stock specular strength and gloss to suit the skin's finish."""
    red, green, blue, gloss = stock_specular.split()
    tint = skin.specular_tint or (255, 255, 255)
    scaled = []
    for channel, tint_value in zip((red, green, blue), tint):
        factor = skin.shine * tint_value / 255
        scaled.append(channel.point(lambda value, f=factor: min(255, int(value * f))))
    scaled_gloss = gloss.point(lambda value: min(255, int(value * skin.gloss)))
    specular = Image.merge("RGBA", (*scaled, scaled_gloss))
    return specular.resize((SPECULAR_SIZE_PX, SPECULAR_SIZE_PX), Image.Resampling.LANCZOS)


def paint_icon(stock_icon, steel_paint):
    """Recolour the stock side-view icon in the skin's black chrome, with neon drawn at icon size.

    The map's own bands are too thin to survive the shrink to an icon.
    """
    width, height = stock_icon.size
    box = (0, ICON_PATTERN_TOP, width * ICON_PATTERN_SCALE, ICON_PATTERN_TOP + height * ICON_PATTERN_SCALE)
    patch = steel_paint.crop(box).resize((width, height), Image.Resampling.LANCZOS)
    # Bring every stock icon to the same average light (the Desert Eagle's is bright silver,
    # the RPG's dark steel), then lift the paint so black chrome keeps its shape.
    alpha = stock_icon.getchannel("A")
    luminance = ImageOps.autocontrast(stock_icon.convert("L"), cutoff=1, mask=alpha)
    mean = ImageStat.Stat(luminance, mask=alpha).mean[0] or 1
    luminance = luminance.point(lambda value: min(255, int(value * ICON_MEAN_LIGHT / mean)))
    lifted = ImageChops.add(patch, flat(ICON_PAINT_LIFT, patch.size))
    glow = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(glow)
    generator = random.Random(9)
    for _ in range(width * height // ICON_PIXELS_PER_BAND):
        x = generator.randrange(-width // 4, width)
        y = generator.randrange(height)
        draw.rectangle((x, y, x + generator.randrange(width // 8, width // 3), y + generator.randrange(0, 2)),
                       fill=generator.choice(GLITCH_COLORS))
    glow = ImageChops.add(glow, glow.filter(ImageFilter.GaussianBlur(1.5)))
    icon = ImageChops.add(shade_with(lifted, luminance), glow).convert("RGBA")
    icon.putalpha(stock_icon.getchannel("A"))
    return icon


# Player models ---------------------------------------------------------------

BODY_MATERIAL = "mtl_usmc_body_mp"
BODY_LOD_MATERIAL = "mtl_usmc_lod_mp"
HELMET_MATERIAL = "mtl_usmc_tactical_mich_stripes_nomex"
ACCESSORIES_MATERIAL = "mtl_accessories_mp"
ACCESSORIES_ALPHA_MATERIAL = "mtl_accessories_alpha_mp"
GLOVE_MATERIAL = "mtl_marine_glove"
GLOVE_SLEEVE_MATERIAL = "mtl_marine_glovesleeve"
BODY_NORMAL = "usmc_body_mp_nml"
STOCK_BODY = "body_mp_usmc_specops"
STOCK_HEAD = "head_mp_usmc_tactical_mich_stripes_nomex"
STOCK_HEAD_SURFACES = "head_mp_usmc_tactical_mich_stripes_nomex_lod01"
STOCK_VIEW_HANDS = "viewmodel_base_viewhands"
THEMED_MATERIALS = (BODY_MATERIAL, BODY_LOD_MATERIAL, HELMET_MATERIAL, ACCESSORIES_MATERIAL,
                    ACCESSORIES_ALPHA_MATERIAL, GLOVE_MATERIAL, GLOVE_SLEEVE_MATERIAL)
# Materials of the head's first LOD, in surface order.
HEAD_SURFACE_MATERIALS = (HELMET_MATERIAL, HELMET_MATERIAL, ACCESSORIES_MATERIAL, ACCESSORIES_MATERIAL,
                          ACCESSORIES_MATERIAL, ACCESSORIES_ALPHA_MATERIAL, BODY_MATERIAL)
# The body has two detailed LODs whose surfaces use the body material, then two
# distant LODs that use the LOD material.
DETAILED_BODY_LODS = ("body_mp_usmc_specops_lod02", "body_mp_usmc_specops_lod12")
BETA_BODY_LODS = ("body_opencj_beta_lod0", "body_opencj_beta_lod1")
BODY_MAP_PX = 1024


class Theme:
    """A recolour of every player model texture: helmet, headset, gloves and body."""

    def __init__(self, name, body, tones, glossy=False):
        self.name = name
        self.body = body
        # Glossy themes get their own specular maps and the weapons' reflection settings.
        self.glossy = glossy
        # Colours for black, mid-grey and white stock pixels.
        self.tones = tones

    def recolor(self, stock, skin_ratio=None):
        """Keep the stock folds and detail in the theme's greys, and any transparency.

        With a skin_ratio, bare skin keeps its stock colour (see skin_mask).
        """
        luminance = ImageOps.autocontrast(stock.convert("L"), cutoff=1)
        recolored = ImageOps.colorize(luminance, self.tones[0], self.tones[2], mid=self.tones[1]).convert("RGBA")
        if skin_ratio is not None:
            recolored = Image.composite(stock, recolored, skin_mask(stock, skin_ratio))
        recolored.putalpha(stock.getchannel("A"))
        return recolored

    def material(self, stock_material):
        return f"mtl_opencj_{self.name}_{stock_material[len('mtl_'):]}"

    def image(self, stock_image):
        return f"opencj_{self.name}_{stock_image}"

    @property
    def head(self):
        return f"head_opencj_{self.name}"

    @property
    def view_hands(self):
        return f"viewhands_opencj_{self.name}"


# Skin is warmer than cloth: green clearly below red, and blue below green. How far
# below depends on the map: the first-person wrists, about (101, 79, 68), sit 22% below,
# next to glove stripes at 9%; on the accessories map the arms sit 31-38% below, next to
# tan cloth at 19-21%.
SKIN_MIN_RED = 80
SKIN_MIN_GREEN_OVER_BLUE = 5
SKIN_RATIO_BY_MATERIAL = {"mtl_marine_glove": 0.18, "mtl_marine_glovesleeve": 0.18,
                          "mtl_usmc_tactical_mich_stripes_nomex": 0.18, "mtl_accessories_mp": 0.26}


def skin_mask(stock, min_red_over_green_ratio):
    red, green, blue = (channel.load() for channel in stock.convert("RGB").split())
    width, height = stock.size
    mask = Image.new("L", stock.size, 0)
    pixels = mask.load()
    for y in range(height):
        for x in range(width):
            r, g, b = red[x, y], green[x, y], blue[x, y]
            if (r >= SKIN_MIN_RED and r - g >= min_red_over_green_ratio * r and
                    g - b >= SKIN_MIN_GREEN_OVER_BLUE):
                pixels[x, y] = 255
    # Opening the mask drops the odd warm speck in the sleeve camouflage.
    return mask.filter(ImageFilter.MinFilter(5)).filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(1))


# Themes are neutral grey: any tint in near-black would be exaggerated by DXT1.
DARK = Theme("dark", "body_opencj_dark", ((10, 10, 10), (42, 42, 42), (140, 140, 140)))
# The beta model is near black, gloves and helmet included.
BLACK = Theme("black", "body_opencj_beta", ((0, 0, 0), (9, 9, 9), (36, 36, 36)), glossy=True)

# Specular strength (grey) and gloss (alpha) of glossy themes, around which the stock
# specular detail varies a little.
GLOSSY_SPECULAR = 150
GLOSSY_SPECULAR_DETAIL = 0.3
GLOSSY_GLOSS = 215
# Reflection settings (envMapParms: minimum, maximum, falloff exponent, sun specular).
# The stock body reflects only at grazing angles (0.4, 12, 3); these follow the chrome
# Desert Eagle (4, 4, 6) for a lacquered, metallic black.
GLOSSY_ENV_MAP = (2.5, 4.0, 4.0, 0.625)
ENV_MAP_NAME_POINTER = 0x64
ENV_MAP_VALUES = 0x68


def glossy_specular(stock_specular, skin):
    """A strong, tight specular map; skin keeps its stock specular."""
    detail = stock_specular.convert("L").point(
        lambda value: max(0, min(255, round(GLOSSY_SPECULAR + (value - 128) * GLOSSY_SPECULAR_DETAIL))))
    glossy = Image.merge("RGBA", (detail, detail, detail, Image.new("L", stock_specular.size, GLOSSY_GLOSS)))
    if skin is not None:
        glossy = Image.composite(stock_specular, glossy, skin.resize(stock_specular.size))
    return glossy.resize((SPECULAR_SIZE_PX, SPECULAR_SIZE_PX), Image.Resampling.LANCZOS)


def with_env_map(material, values):
    """Set a model material's reflection constants."""
    name_offset = struct.unpack_from("<I", material, ENV_MAP_NAME_POINTER)[0]
    if read_c_string(material, name_offset) != "envMapParms":
        raise ValueError("Material does not hold envMapParms where measured")
    patched = bytearray(material)
    struct.pack_into("<4f", patched, ENV_MAP_VALUES, *values)
    return bytes(patched)

# DXT1 stores green with six bits but red and blue with five. Near black, the encoder then
# rounds greys towards green. Snapping every channel to a five-bit level (which green
# also stores exactly), with an ordered dither against banding, keeps greys neutral.
DXT1_LEVEL = 255 / 31
BAYER_4X4 = (0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5)


def dxt1_neutral(image):
    tile = Image.new("L", (4, 4))
    tile.putdata([round((value + 0.5) / 16 * DXT1_LEVEL) for value in BAYER_4X4])
    dither = Image.new("L", image.size)
    for y in range(0, image.height, 4):
        for x in range(0, image.width, 4):
            dither.paste(tile, (x, y))
    snap = [min(255, round(int(value / DXT1_LEVEL) * DXT1_LEVEL)) for value in range(256)]
    channels = [ImageChops.add(channel, dither).point(snap) for channel in image.convert("RGB").split()]
    snapped = Image.merge("RGB", channels).convert("RGBA")
    snapped.putalpha(image.getchannel("A") if image.mode == "RGBA" else Image.new("L", image.size, 255))
    return snapped


class SurfaceMesh:
    """The vertices and triangles of one surface in a raw xmodelsurfs file (version 25)."""

    def __init__(self, vertex_offsets, normals, uvs, positions, triangles):
        self.vertex_offsets = vertex_offsets
        self.normals = normals
        self.uvs = uvs
        self.positions = positions
        self.triangles = triangles


XMODELSURFS_VERSION = 25
# Vertex records: normal, colour, uv, binormal, tangent; then weighted surfaces add a
# weight count and a bone before the position and four bytes per extra weight.
VERTEX_UV_OFFSET = 16
VERTEX_TANGENTS_END = 48
RIGID_VERTEX_BYTES = 60
WEIGHTED_VERTEX_BYTES = 63
WEIGHT_BYTES = 4
SURFACE_HEADER_SEARCH_BYTES = 4096


def _parse_vertices(data, start, vertex_count, weighted):
    offsets, normals, uvs, positions = [], [], [], []
    offset = start
    for _ in range(vertex_count):
        if offset + RIGID_VERTEX_BYTES > len(data):
            return None
        normal = struct.unpack_from("<3f", data, offset)
        if not all(math.isfinite(value) for value in normal):
            return None
        if abs(sum(value * value for value in normal) - 1) > 0.02:
            return None
        offsets.append(offset)
        normals.append(normal)
        uvs.append(struct.unpack_from("<2f", data, offset + VERTEX_UV_OFFSET))
        if weighted:
            weight_count = data[offset + VERTEX_TANGENTS_END]
            if weight_count > 8:
                return None
            positions.append(struct.unpack_from("<3f", data, offset + VERTEX_TANGENTS_END + 3))
            offset += WEIGHTED_VERTEX_BYTES + weight_count * WEIGHT_BYTES
        else:
            positions.append(struct.unpack_from("<3f", data, offset + VERTEX_TANGENTS_END))
            offset += RIGID_VERTEX_BYTES
    return offsets, normals, uvs, positions, offset


def parse_surfaces(data):
    """Locate each surface's vertices; the parse must account for every byte."""
    version, surface_count = struct.unpack_from("<HH", data, 0)
    if version != XMODELSURFS_VERSION:
        raise ValueError(f"Unsupported xmodelsurfs version {version}")
    offset = 4
    surfaces = []
    for _ in range(surface_count):
        _, _, vertex_count, triangle_count = struct.unpack_from("<BHHH", data, offset)
        found = None
        # The header's bone table varies in length, so find where the vertices start.
        for start in range(offset + 7, offset + SURFACE_HEADER_SEARCH_BYTES):
            for weighted in (True, False):
                parsed = _parse_vertices(data, start, vertex_count, weighted)
                if not parsed:
                    continue
                offsets, normals, uvs, positions, end = parsed
                if end + 6 * triangle_count > len(data):
                    continue
                triangles = [struct.unpack_from("<3H", data, end + 6 * index)
                             for index in range(triangle_count)]
                if max(max(triangle) for triangle in triangles) >= vertex_count:
                    continue
                found = SurfaceMesh(offsets, normals, uvs, positions, triangles), end + 6 * triangle_count
                break
            if found:
                break
        if not found:
            raise ValueError("Could not locate a surface's vertices")
        surfaces.append(found[0])
        offset = found[1]
    if offset != len(data):
        raise ValueError("Surface parse did not end at the end of the file")
    return surfaces


def mesh_pieces(surface):
    """Label each vertex with the connected piece its triangles form."""
    parent = list(range(len(surface.positions)))

    def root(index):
        while parent[index] != index:
            parent[index] = parent[parent[index]]
            index = parent[index]
        return index

    for first, second, third in surface.triangles:
        parent[root(second)] = root(first)
        parent[root(third)] = root(first)
    return [root(index) for index in range(len(surface.positions))]


class BackpackMark:
    """Print the beta mark on the backpack, projected straight from behind.

    The body mirrors its back texture across the spine, so a mark painted in place
    would show twice. The backpack pieces instead get new coordinates in the
    otherwise unused lower half of the colour map, where the mark is painted once.
    The vest behind the backpack keeps its stock coordinates.
    """

    # Model space: +x is forward, +y is the player's left and +z is up. Only the
    # backpack reaches this far behind the spine.
    BACKPACK_MAX_X = -11.5
    BACKPACK_MIN_Z = 30.0
    BACKPACK_MAX_Z = 60.0
    FACING_BACK = -0.6
    MARGIN_PX = 4
    MARK_FILL = 0.7
    # Raise the mark by this share of the backpack's height, to sit on its upper panel.
    MARK_RAISE = 0.15

    def __init__(self, map_px, lod0_data):
        self.map_px = map_px
        self.centre = (map_px / 2, map_px * 3 / 4)
        points = []
        back_face = []
        for surface in parse_surfaces(lod0_data):
            for index in self._backpack_vertices(surface):
                position = surface.positions[index]
                points.append(position)
                if surface.normals[index][0] < self.FACING_BACK:
                    back_face.append(position)
        if not back_face:
            raise ValueError("No backpack found on the body")
        span_y = max(p[1] for p in points) - min(p[1] for p in points)
        span_z = max(p[2] for p in points) - min(p[2] for p in points)
        usable_px = map_px / 2 - 2 * self.MARGIN_PX
        self.pixels_per_unit = min((map_px - 2 * self.MARGIN_PX) / span_y, usable_px / span_z)
        face_y = [p[1] for p in back_face]
        face_z = [p[2] for p in back_face]
        self.face_centre = ((min(face_y) + max(face_y)) / 2, (min(face_z) + max(face_z)) / 2)
        self.face_height_px = (max(face_z) - min(face_z)) * self.pixels_per_unit
        self.face_size_px = (min(max(face_y) - min(face_y), max(face_z) - min(face_z)) *
                             self.pixels_per_unit)

    def _backpack_vertices(self, surface):
        pieces = mesh_pieces(surface)
        backpack = {pieces[index] for index, (x, _, z) in enumerate(surface.positions)
                    if x < self.BACKPACK_MAX_X and self.BACKPACK_MIN_Z < z < self.BACKPACK_MAX_Z and
                    surface.normals[index][0] < self.FACING_BACK}
        return [index for index in range(len(pieces)) if pieces[index] in backpack]

    def uv(self, position):
        _, y, z = position
        centre_y, centre_z = self.face_centre
        # The player's left (+y) must appear on the left when seen from behind.
        u_px = self.centre[0] - (y - centre_y) * self.pixels_per_unit
        v_px = self.centre[1] + (centre_z - z) * self.pixels_per_unit
        u_px = min(max(u_px, self.MARGIN_PX), self.map_px - self.MARGIN_PX)
        v_px = min(max(v_px, self.map_px / 2 + self.MARGIN_PX), self.map_px - self.MARGIN_PX)
        return u_px / self.map_px, v_px / self.map_px

    def remap(self, data):
        """Return the surfaces file with new coordinates for the backpack pieces."""
        output = bytearray(data)
        remapped = 0
        for surface in parse_surfaces(data):
            for index in self._backpack_vertices(surface):
                struct.pack_into("<2f", output, surface.vertex_offsets[index] + VERTEX_UV_OFFSET,
                                 *self.uv(surface.positions[index]))
                remapped += 1
        if not remapped:
            raise ValueError("No backpack pieces found to remap")
        return bytes(output)

    def paint(self, body):
        """Fill the lower half with the body's plain fabric and print the mark."""
        width, height = body.size
        half_height = height // 2
        tone = body.convert("L").crop((0, 0, width, half_height)).resize((1, 1)).getpixel((0, 0))
        noise = smooth_noise(seed=21, cells=48, size=(width, half_height))
        fabric = ImageOps.colorize(noise, (max(0, tone - 5),) * 3, (min(255, tone + 5),) * 3)
        painted = body.convert("RGB")
        painted.paste(fabric, (0, half_height))
        mark_px = round(self.face_size_px * self.MARK_FILL)
        centre = (round(self.centre[0]), round(self.centre[1] - self.face_height_px * self.MARK_RAISE))
        glow = Image.new("RGB", body.size, (0, 0, 0))
        draw_beta(glow, centre, mark_px, (0, 170, 190))
        painted = ImageChops.add(painted, glow.filter(ImageFilter.GaussianBlur(max(2, mark_px // 30))))
        draw_beta(painted, centre, mark_px, (214, 222, 230))
        painted = painted.convert("RGBA")
        return painted


# Icon rendering --------------------------------------------------------------

ICON_PX = 128
ICON_SUPERSAMPLE = 3
ICON_AMBIENT = 0.55
ICON_DIFFUSE = 0.75


def render_model(parts, yaw_degrees, frame_min_z, brightness):
    """Render textured surfaces with a depth buffer, seen from a horizontal angle.

    parts is a list of (SurfaceMesh, RGBA texture), in the bind pose. The view is
    framed on everything above frame_min_z. brightness scales the texture colours,
    since a near-black model would vanish at icon size.
    """
    size = ICON_PX * ICON_SUPERSAMPLE
    yaw = math.radians(yaw_degrees)
    view = (math.cos(yaw), math.sin(yaw))
    right = (-view[1], view[0])
    light = (view[0] * 0.6 + right[0] * 0.4, view[1] * 0.6 + right[1] * 0.4, 0.7)
    light_length = math.sqrt(sum(value * value for value in light))
    light = tuple(value / light_length for value in light)
    projected = [[(p[0] * right[0] + p[1] * right[1], p[2], p[0] * view[0] + p[1] * view[1])
                  for p in surface.positions] for surface, _ in parts]
    all_points = [point for points in projected for point in points if point[1] >= frame_min_z]
    min_x = min(p[0] for p in all_points)
    max_x = max(p[0] for p in all_points)
    min_y = min(p[1] for p in all_points)
    max_y = max(p[1] for p in all_points)
    scale = (size * 0.94) / max(max_x - min_x, max_y - min_y)
    offset_x = size / 2 - (min_x + max_x) / 2 * scale
    offset_y = size / 2 + (min_y + max_y) / 2 * scale
    depth = [-1e9] * (size * size)
    color = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    pixels = color.load()
    for (surface, texture), points in zip(parts, projected):
        texels = texture.load()
        texture_width, texture_height = texture.size
        screen = [(p[0] * scale + offset_x, offset_y - p[1] * scale, p[2]) for p in points]
        uvs = surface.uvs
        normals = surface.normals
        for a, b, c in surface.triangles:
            ax, ay, az = screen[a]
            bx, by, bz = screen[b]
            cx, cy, cz = screen[c]
            area = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
            if abs(area) < 1e-9:
                continue
            for py in range(max(0, int(min(ay, by, cy))), min(size - 1, int(max(ay, by, cy)) + 1) + 1):
                sy = py + 0.5
                for px in range(max(0, int(min(ax, bx, cx))), min(size - 1, int(max(ax, bx, cx)) + 1) + 1):
                    sx = px + 0.5
                    w0 = ((bx - sx) * (cy - sy) - (by - sy) * (cx - sx)) / area
                    w1 = ((cx - sx) * (ay - sy) - (cy - sy) * (ax - sx)) / area
                    w2 = 1 - w0 - w1
                    if w0 < 0 or w1 < 0 or w2 < 0:
                        continue
                    z = w0 * az + w1 * bz + w2 * cz
                    index = py * size + px
                    if z <= depth[index]:
                        continue
                    u = w0 * uvs[a][0] + w1 * uvs[b][0] + w2 * uvs[c][0]
                    v = w0 * uvs[a][1] + w1 * uvs[b][1] + w2 * uvs[c][1]
                    texel = texels[int((u % 1) * texture_width) % texture_width,
                                   int((v % 1) * texture_height) % texture_height]
                    if texel[3] < 128:
                        continue
                    normal = [w0 * normals[a][k] + w1 * normals[b][k] + w2 * normals[c][k] for k in range(3)]
                    length = math.sqrt(sum(value * value for value in normal)) or 1
                    lit = brightness * (ICON_AMBIENT + ICON_DIFFUSE *
                                             abs(sum(normal[k] * light[k] for k in range(3))) / length)
                    depth[index] = z
                    pixels[px, py] = (min(255, int(texel[0] * lit)), min(255, int(texel[1] * lit)),
                                      min(255, int(texel[2] * lit)), 255)
    return color.resize((ICON_PX, ICON_PX), Image.Resampling.LANCZOS)


# Build -----------------------------------------------------------------------


class Output:
    def __init__(self, preview_dir):
        self.manifest = []
        self.images = set()
        self.preview_dir = preview_dir

    def write(self, relative_path, data):
        path = COD4 / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        self.manifest.append((path.relative_to(CLIENT_ROOT).as_posix(), hashlib.sha256(data).hexdigest()))

    def image(self, name, image, format_code, flags):
        self.images.add(name)
        self.write(f"images/{name}.iwi", encode_dxt_iwi(image, format_code, flags))
        if self.preview_dir:
            self.preview_dir.mkdir(parents=True, exist_ok=True)
            image.save(self.preview_dir / f"{name}.png")


def stock_file(options, folder, name):
    return (options.stock_raw / folder / name).read_bytes()


def write_material(options, output, template_name, new_name, renames, pointers, env_map=None):
    renames = dict(renames, **{template_name: new_name})
    material = clone_material(stock_file(options, "materials", template_name), renames, pointers)
    if env_map:
        material = with_env_map(material, env_map)
    output.write(f"materials/{new_name}", material)
    output.write(f"material_properties/{new_name}",
                 stock_file(options, "material_properties", template_name))


def build_weapon_skins(options, output, base, weapon_template):
    stock_color, color_flags = decode_iwi(read_stock_image(options.game_main, base.color_image))
    stock_specular, specular_flags = decode_iwi(read_stock_image(options.game_main, base.specular_image))
    stock_icon, icon_flags = decode_iwi(read_stock_image(options.game_main, base.icon))
    surfaces = StockSurfaces(stock_color, base.grip_outline, base.kept_areas, base.dark_detail,
                             base.stretch_shading)
    texel_scale = TexelScale()
    if base.view_surfaces:
        texel_scale = TexelScale(stock_file(options, "xmodelsurfs", base.view_surfaces),
                                 stock_file(options, "xmodelsurfs", DEAGLE_VIEW_SURFACES))
    tube = TubeStripes(stock_file(options, "xmodelsurfs", base.view_surfaces)) if base.has_tube else None
    for skin in SKINS:
        assets = SkinAssets(base, skin.slug)
        steel_paint, grip_paint, glow = skin.paint(base, surfaces.size, texel_scale)
        detail = texel_scale.halo_mask(surfaces.size) if base.view_surfaces else None
        if tube is not None:
            detail, glow = tube.apply(detail, glow)
        output.image(assets.color_image, surfaces.compose(steel_paint, grip_paint, glow, detail),
                     IWI_FORMAT_DXT1, color_flags)
        output.image(assets.specular_image, specular_map(skin, stock_specular), IWI_FORMAT_DXT5, specular_flags)
        write_material(options, output, base.material, assets.material,
                       {base.color_image: assets.color_image, base.specular_image: assets.specular_image},
                       MODEL_MATERIAL_POINTERS)
        for _, stock_model, slots in base.models:
            output.write(f"xmodel/{assets.model(stock_model)}",
                         clone_model(stock_file(options, "xmodel", stock_model),
                                     {base.material: (assets.material, slots)}))
        output.write(f"weapons/mp/{assets.weapon}",
                     clone_weapon(weapon_template, base, assets).encode("ascii"))
        output.image(assets.icon, paint_icon(stock_icon, steel_paint),
                     IWI_FORMAT_DXT5, icon_flags)
        write_material(options, output, base.icon, assets.icon, {}, ICON_MATERIAL_POINTERS)


def stock_specular_image(options, material):
    """The specular map a stock model material points at."""
    template = stock_file(options, "materials", material)
    return read_c_string(template, struct.unpack_from("<I", template, MODEL_SPECULAR_POINTER)[0])


def stock_color_image(options, material):
    """The colour map a stock model material points at."""
    template = stock_file(options, "materials", material)
    return read_c_string(template, struct.unpack_from("<I", template, MODEL_MATERIAL_POINTERS[1])[0])


def build_theme(options, output, theme, body_paint=None, body_overrides=None, body_lods=None):
    """Recolour every player texture for a theme and write its materials and models.

    Returns the recoloured colour maps by stock material, for rendering icons.
    """
    textures = {}
    skins = {}
    for material in THEMED_MATERIALS:
        stock_image = stock_color_image(options, material)
        new_image = theme.image(stock_image)
        if new_image not in output.images:
            stock, flags = decode_iwi(read_stock_image(options.game_main, stock_image))
            # Bare skin (arms, wrists, around the eyes) keeps its colour; the body is all cloth.
            skin_ratio = SKIN_RATIO_BY_MATERIAL.get(material)
            texture = theme.recolor(stock, skin_ratio)
            skins[stock_image] = skin_mask(stock, skin_ratio) if skin_ratio is not None else None
            if material == BODY_MATERIAL:
                texture = texture.resize((BODY_MAP_PX, BODY_MAP_PX), Image.Resampling.LANCZOS)
                if body_paint:
                    texture = body_paint(texture)
            texture = dxt1_neutral(texture)
            # Only the goggle lenses need their transparency.
            format_code = IWI_FORMAT_DXT5 if material == ACCESSORIES_ALPHA_MATERIAL else IWI_FORMAT_DXT1
            output.image(new_image, texture, format_code, flags)
            textures[stock_image] = texture
        textures[material] = textures[stock_image]
        renames = {stock_image: new_image}
        if material == BODY_MATERIAL and body_overrides:
            renames.update(body_overrides)
        env_map = None
        # The goggle lenses keep their stock finish.
        if theme.glossy and material != ACCESSORIES_ALPHA_MATERIAL:
            stock_specular = stock_specular_image(options, material)
            new_specular = f"opencj_{theme.name}_{material[len('mtl_'):]}_spec"
            if new_specular not in output.images:
                specular, specular_flags = decode_iwi(read_stock_image(options.game_main, stock_specular))
                output.image(new_specular, glossy_specular(specular, skins.get(stock_image)), IWI_FORMAT_DXT5,
                             specular_flags)
            renames[stock_specular] = new_specular
            env_map = GLOSSY_ENV_MAP
        write_material(options, output, material, theme.material(material), renames, MODEL_MATERIAL_POINTERS,
                       env_map)

    head_renames = {material: (theme.material(material), count) for material, count in (
        (HELMET_MATERIAL, 4), (ACCESSORIES_MATERIAL, 5), (ACCESSORIES_ALPHA_MATERIAL, 2),
        (BODY_MATERIAL, 2), (BODY_LOD_MATERIAL, 2))}
    output.write(f"xmodel/{theme.head}", clone_model(stock_file(options, "xmodel", STOCK_HEAD), head_renames))
    output.write(f"xmodel/{theme.view_hands}", clone_model(stock_file(options, "xmodel", STOCK_VIEW_HANDS), {
        GLOVE_MATERIAL: (theme.material(GLOVE_MATERIAL), 1),
        GLOVE_SLEEVE_MATERIAL: (theme.material(GLOVE_SLEEVE_MATERIAL), 1),
    }))
    body_renames = {BODY_MATERIAL: (theme.material(BODY_MATERIAL), 4),
                    BODY_LOD_MATERIAL: (theme.material(BODY_LOD_MATERIAL), 2)}
    body_renames.update(body_lods or {})
    output.write(f"xmodel/{theme.body}", clone_model(stock_file(options, "xmodel", STOCK_BODY), body_renames))
    return {material: textures[material] for material in THEMED_MATERIALS}


# The head's surfaces are stored in its neck bone's frame (x up, y forward, z to the
# side); this places them on the body in the bind pose.
HEAD_FORWARD_OFFSET = -4.0
HEAD_UP_OFFSET = 51.5
# The icon shows the upper body, where the mark is.
ICON_FRAME_MIN_Z = 26.0


def model_icon(options, textures, body_surfaces, yaw_degrees, brightness):
    parts = [(surface, textures[BODY_MATERIAL]) for surface in parse_surfaces(body_surfaces)]
    head = parse_surfaces(stock_file(options, "xmodelsurfs", STOCK_HEAD_SURFACES))
    if len(head) != len(HEAD_SURFACE_MATERIALS):
        raise ValueError("The head's surfaces no longer match their materials")
    for surface in head:
        surface.positions = [(y + HEAD_FORWARD_OFFSET, z, x + HEAD_UP_OFFSET) for x, y, z in surface.positions]
        surface.normals = [(y, z, x) for x, y, z in surface.normals]
    parts += [(surface, textures[material]) for surface, material in zip(head, HEAD_SURFACE_MATERIALS)]
    return render_model(parts, yaw_degrees, ICON_FRAME_MIN_Z, brightness)


def build_player_models(options, output):
    # Everyone owns the dark model; the shop lists it to switch back from the beta model.
    dark_textures = build_theme(options, output, DARK)
    icon_flags = decode_iwi(read_stock_image(options.game_main, DEAGLE.icon))[1]
    icon = model_icon(options, dark_textures, stock_file(options, "xmodelsurfs", DETAILED_BODY_LODS[0]),
                      yaw_degrees=25, brightness=1.1)
    output.image("opencj_shop_model_dark", icon, IWI_FORMAT_DXT5, icon_flags)
    write_material(options, output, DEAGLE.icon, "opencj_shop_model_dark", {}, ICON_MATERIAL_POINTERS)

    mark = BackpackMark(BODY_MAP_PX, stock_file(options, "xmodelsurfs", DETAILED_BODY_LODS[0]))
    body_lods = {}
    remapped_lods = []
    for stock_lod, beta_lod in zip(DETAILED_BODY_LODS, BETA_BODY_LODS):
        body_lods[stock_lod] = (beta_lod, 1)
        remapped_lods.append(mark.remap(stock_file(options, "xmodelsurfs", stock_lod)))
        output.write(f"xmodelsurfs/{beta_lod}", remapped_lods[-1])
    # Bones come from the first LOD's parts file, which the renamed LOD must also have.
    output.write(f"xmodelparts/{BETA_BODY_LODS[0]}", stock_file(options, "xmodelparts", DETAILED_BODY_LODS[0]))
    # The stock normal map holds other bodies in its lower half, where the backpack now
    # samples, so the beta body uses flat normals. Its glossy specular map is even there.
    textures = build_theme(options, output, BLACK, body_paint=mark.paint, body_lods=body_lods,
                           body_overrides={BODY_NORMAL: "$identitynormalmap"})

    # Seen from behind and to the side, so the mark on the backpack shows.
    icon = model_icon(options, textures, remapped_lods[0], yaw_degrees=200, brightness=2.6)
    output.image("opencj_shop_model_beta", icon, IWI_FORMAT_DXT5, icon_flags)
    write_material(options, output, DEAGLE.icon, "opencj_shop_model_beta", {}, ICON_MATERIAL_POINTERS)


def build_stock_weapon_hands(options, output):
    """Let player models replace the hands of the stock Desert Eagle too.

    OpenCJ's rpg_mp sets the same flag in the repository.
    """
    output.write("weapons/mp/deserteagle_mp",
                 playable_weapon(options.stock_deagle.read_text(encoding="ascii"), "deserteagle_mp")
                 .encode("ascii"))


def build(options):
    output = Output(options.preview_dir)
    build_weapon_skins(options, output, DEAGLE, options.stock_deagle.read_text(encoding="ascii"))
    build_weapon_skins(options, output, RPG, OPENCJ_RPG_WEAPON.read_text(encoding="ascii"))
    build_stock_weapon_hands(options, output)
    build_player_models(options, output)
    for relative_path, digest in output.manifest:
        print(digest, relative_path)
    print(f"Built the Beta collection and player models ({len(output.manifest)} files).")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--game-main", type=Path, required=True)
    parser.add_argument("--stock-raw", type=Path, required=True)
    parser.add_argument("--stock-deagle", type=Path, required=True)
    parser.add_argument("--preview-dir", type=Path)
    build(parser.parse_args())


if __name__ == "__main__":
    main()
