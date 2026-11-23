"""Audio conversion behavior without libsndfile, game assets or persistent outputs."""

import ctypes
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import wave

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build-finish-sounds.py"
SPEC = importlib.util.spec_from_file_location("finish_sounds", SCRIPT)
audio = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(audio)


class Decoder:
    """Supply metadata at the native boundary and record handle cleanup."""

    def __init__(self, *, frames=2, channels=1, sample_rate=44100, fail_read=False):
        self.frames = frames
        self.channels = channels
        self.sample_rate = sample_rate
        self.fail_read = fail_read
        self.read_calls = 0
        self.closed = False

    def sf_open(self, path, mode, info_pointer):
        info = ctypes.cast(info_pointer, ctypes.POINTER(audio.SoundFileInfo)).contents
        info.frames = self.frames
        info.channels = self.channels
        info.samplerate = self.sample_rate
        return 1

    def sf_readf_float(self, handle, buffer, frames):
        self.read_calls += 1
        if self.fail_read:
            raise OSError("synthetic decoder failure")
        buffer[0] = 0.25
        buffer[1] = -0.25
        return 2

    def sf_close(self, handle):
        self.closed = True
        return 0


class FinishSoundTests(unittest.TestCase):
    def test_stereo_interpolation_keeps_channels_separate(self):
        result = audio.resample_audio([0, 1, 1, 0], 2, 22050)
        self.assertEqual(result, [0, 1, 0.5, 0.5, 1, 0, 1, 0])

    def test_matching_sample_rate_preserves_samples(self):
        samples = [0.25, -0.25, 0]
        self.assertEqual(audio.resample_audio(samples, 1, 44100), samples)

    def test_invalid_metadata_closes_before_reading(self):
        for metadata in [{"frames": 0}, {"channels": 3}, {"sample_rate": 0}]:
            with self.subTest(metadata=metadata):
                decoder = Decoder(**metadata)
                with self.assertRaisesRegex(ValueError, "mono or stereo"):
                    audio.read_audio(decoder, Path("synthetic.mp3"))
                self.assertEqual(decoder.read_calls, 0)
                self.assertTrue(decoder.closed)

    def test_decoder_failure_releases_handle(self):
        decoder = Decoder(fail_read=True)
        with self.assertRaisesRegex(OSError, "synthetic decoder failure"):
            audio.read_audio(decoder, Path("synthetic.mp3"))
        self.assertTrue(decoder.closed)

    def test_decoding_returns_samples_and_releases_handle(self):
        decoder = Decoder()
        self.assertEqual(
            audio.read_audio(decoder, Path("synthetic.mp3")),
            ([0.25, -0.25], 1, 44100),
        )
        self.assertTrue(decoder.closed)

    def test_silence_has_zero_pcm_and_no_finite_dbfs(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "silent.wav"
            report = audio.write_audio([0, 0], 1, destination)
            with wave.open(str(destination), "rb") as output:
                self.assertEqual(output.getnchannels(), 1)
                self.assertEqual(output.getsampwidth(), 2)
                self.assertEqual(output.getframerate(), 44100)
                self.assertEqual(output.readframes(2), bytes(4))
            self.assertEqual(report["gain_db"], 0)
            self.assertIsNone(report["peak_dbfs"])
            self.assertIsNone(report["rms_dbfs"])

    def test_rms_cap_applies_to_pcm_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "loud.wav"
            report = audio.write_audio([0.5, -0.5], 1, destination)
            with wave.open(str(destination), "rb") as output:
                self.assertEqual(struct.unpack("<hh", output.readframes(2)), (3277, -3277))
            self.assertEqual(report["rms_dbfs"], -20)

    def test_invalid_samples_preserve_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "existing.wav"
            destination.write_bytes(b"previous output")
            for samples in [[], [float("nan")], [float("inf")]]:
                with self.subTest(samples=samples):
                    with self.assertRaises(ValueError):
                        audio.write_audio(samples, 1, destination)
                    self.assertEqual(destination.read_bytes(), b"previous output")


if __name__ == "__main__":
    unittest.main()
