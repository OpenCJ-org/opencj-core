"""Encode the CoD4 IWI layout shared by first-party texture generators."""

import struct

from PIL import Image

IWI_VERSION_COD4 = 6
IWI_FORMAT_RGBA = 1
IWI_FORMAT_DXT1 = 11
IWI_FORMAT_DXT5 = 13
IWI_HEADER_BYTES = 28
IWI_RECORDED_MIP_OFFSETS = 4


def mipmaps(image):
    """Keep the full-size image first and finish at one pixel in each dimension."""
    images = [image]
    while images[-1].width > 1 or images[-1].height > 1:
        previous = images[-1]
        next_width = max(1, previous.width // 2)
        next_height = max(1, previous.height // 2)
        # RGBA resampling uses premultiplied alpha so transparent edges stay clean.
        images.append(previous.resize((next_width, next_height), Image.Resampling.LANCZOS))
    return images


def encode_iwi(width, height, encoded_mips, format_code, flags=0):
    """Write offsets from the file start, followed by smallest-to-largest mip payloads."""
    if not encoded_mips:
        raise ValueError("An IWI texture needs at least one mip payload")
    header = b"IWi" + bytes((IWI_VERSION_COD4, format_code, flags))
    header += struct.pack("<HHH", width, height, 1)
    file_sizes = []
    for first_mip in range(IWI_RECORDED_MIP_OFFSETS):
        # A single-level texture repeats its one file size in all four header slots.
        stored_first_mip = min(first_mip, len(encoded_mips) - 1)
        payload_bytes = sum(len(mip) for mip in encoded_mips[stored_first_mip:])
        file_sizes.append(IWI_HEADER_BYTES + payload_bytes)
    header += struct.pack("<4I", *file_sizes)
    return header + b"".join(reversed(encoded_mips))
