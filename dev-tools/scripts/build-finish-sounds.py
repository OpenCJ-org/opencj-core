"""Decode the supplied MP3s with libsndfile into quiet 44.1 kHz PCM16 game assets."""

import argparse
import array
import ctypes
import ctypes.util
import json
import math
from pathlib import Path
import sys
import wave

ROOT = Path(__file__).resolve().parents[2]
OUTPUT_SAMPLE_RATE = 44100
PCM_SAMPLE_BYTES = 2
PCM_POSITIVE_PEAK = 32767
PEAK_LIMIT_DBFS = -6
RMS_LIMIT_DBFS = -20
SNDFILE_READ_MODE = 0x10
SOURCES = [
    ("freesound_gamestudio-level-complete-394515.mp3", "route_complete.wav"),
    ("universfield-victory-fanfare-152480.mp3", "route_record.wav"),
]


class SoundFileInfo(ctypes.Structure):
    """Keep the field order and widths of libsndfile's SF_INFO ABI."""

    _fields_ = [
        ("frames", ctypes.c_int64),
        ("samplerate", ctypes.c_int),
        ("channels", ctypes.c_int),
        ("format", ctypes.c_int),
        ("sections", ctypes.c_int),
        ("seekable", ctypes.c_int),
    ]


def load_decoder():
    library_path = ctypes.util.find_library("sndfile")
    if not library_path:
        raise RuntimeError("libsndfile with MP3 support is required")
    decoder = ctypes.CDLL(library_path)
    decoder.sf_open.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.POINTER(SoundFileInfo)]
    decoder.sf_open.restype = ctypes.c_void_p
    decoder.sf_readf_float.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.c_int64
    ]
    decoder.sf_readf_float.restype = ctypes.c_int64
    decoder.sf_close.argtypes = [ctypes.c_void_p]
    decoder.sf_close.restype = ctypes.c_int
    return decoder


def read_audio(decoder, path):
    """Decode interleaved samples and release the file even when decoding fails."""
    info = SoundFileInfo()
    handle = decoder.sf_open(str(path).encode(), SNDFILE_READ_MODE, ctypes.byref(info))
    if not handle:
        raise RuntimeError("Cannot decode " + str(path))
    try:
        if info.frames <= 0 or info.samplerate <= 0 or info.channels not in (1, 2):
            raise ValueError("Expected nonempty mono or stereo audio: " + str(path))
        raw_samples = (ctypes.c_float * (info.frames * info.channels))()
        decoded_frames = decoder.sf_readf_float(handle, raw_samples, info.frames)
        # MP3 frame estimates can include encoder padding beyond the decoded end.
        if not 0 < decoded_frames <= info.frames:
            raise ValueError("Decoder returned an invalid frame count: " + str(path))
        samples = list(raw_samples[:decoded_frames * info.channels])
    finally:
        decoder.sf_close(handle)
    return samples, info.channels, info.samplerate


def resample_audio(samples, channels, source_sample_rate):
    """Linearly interpolate each channel without mixing adjacent channels."""
    if source_sample_rate == OUTPUT_SAMPLE_RATE:
        return samples
    frame_count = len(samples) // channels
    source_frames_per_output_frame = source_sample_rate / OUTPUT_SAMPLE_RATE
    output_samples = []
    for frame_index in range(round(frame_count / source_frames_per_output_frame)):
        source_position = frame_index * source_frames_per_output_frame
        interpolation_factor = source_position % 1
        first_frame = min(int(source_position), frame_count - 1)
        next_frame = min(int(source_position) + 1, frame_count - 1)
        for channel in range(channels):
            first_sample = samples[first_frame * channels + channel]
            next_sample = samples[next_frame * channels + channel]
            output_samples.append(
                first_sample * (1 - interpolation_factor) + next_sample * interpolation_factor
            )
    return output_samples


def decibels(amplitude):
    # Silence has no finite dBFS value; represent it as null in the JSON report.
    return round(20 * math.log10(amplitude), 2) if amplitude > 0 else None


def write_audio(samples, channels, destination):
    """Never amplify the source; cap peaks and RMS before encoding signed PCM."""
    if not samples or not all(math.isfinite(sample) for sample in samples):
        raise ValueError("Audio must contain finite decoded samples")
    peak = max(abs(sample) for sample in samples)
    rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
    gain = 1
    if peak > 0:
        gain = min(1, 10 ** (PEAK_LIMIT_DBFS / 20) / peak, 10 ** (RMS_LIMIT_DBFS / 20) / rms)
    pcm = array.array("h", (round(sample * gain * PCM_POSITIVE_PEAK) for sample in samples))
    if sys.byteorder != "little":
        pcm.byteswap()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(PCM_SAMPLE_BYTES)
        output.setframerate(OUTPUT_SAMPLE_RATE)
        output.writeframes(pcm.tobytes())
    return {
        "seconds": round(len(samples) / channels / OUTPUT_SAMPLE_RATE, 3),
        "channels": channels,
        "gain_db": decibels(gain),
        "peak_dbfs": decibels(peak * gain),
        "rms_dbfs": decibels(rms * gain),
        "alias_volume": 0.5,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "client-mod/cod4/sound/opencj")
    options = parser.parse_args()
    decoder = load_decoder()
    report = []
    for source_name, target_name in SOURCES:
        source = ROOT / "client-mod/audio-source" / source_name
        samples, channels, sample_rate = read_audio(decoder, source)
        samples = resample_audio(samples, channels, sample_rate)
        levels = write_audio(samples, channels, options.output_dir / target_name)
        report.append({"source": source_name, "output": target_name, **levels})
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
