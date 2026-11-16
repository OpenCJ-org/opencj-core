import argparse
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("dev", Path(__file__).resolve().parents[1] / "dev.py")
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.here = self.root / "dev-tools"
        self.here.mkdir()
        self.game = self.root / "game files"
        (self.game / "main").mkdir(parents=True)
        (self.game / "zone").mkdir()
        self.mod = self.root / "compiled assets"
        self.mod.mkdir()
        self.args = argparse.Namespace(game_dir=str(self.game), mod_dir=str(self.mod),
                                       map="mp_killhouse", port=28961, bind_ip="127.0.0.1")
        for patcher in (patch.object(dev, "HERE", self.here),
                        patch.object(dev.os, "getuid", return_value=1000, create=True),
                        patch.object(dev.os, "getgid", return_value=1000, create=True)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_initializes_and_preserves_configuration(self):
        with patch.object(dev, "run") as run:
            dev.initialize(self.args)
        self.assertEqual(run.call_count, 7)
        calls = run.call_args_list
        self.assertIn("opencj", calls[0].args)
        env = (self.here / ".env").read_text()
        config_path = self.here / "local/runtime/mods/opencj/opencj-dev.cfg"
        config = config_path.read_text()
        password = next(line.split("=", 1)[1].strip("'") for line in env.splitlines() if line.startswith("DB_PASSWORD="))
        self.assertIn(f'set db_pass "{password}"', config)
        self.assertIn("SERVER_PORT='28961'", env)
        self.assertFalse((self.game / "mods").exists())
        with self.assertRaisesRegex(ValueError, "Already initialized"):
            dev.initialize(self.args)
        self.assertEqual(config_path.read_text(), config)
        self.assertEqual((self.here / ".env").read_text(), env)

    def test_wrong_origin_does_not_modify_checkout(self):
        (self.root / "cod4x-server").mkdir()
        with patch.object(dev.subprocess, "check_output", return_value="https://github.com/example/server.git\n"), patch.object(dev, "run") as run:
            with self.assertRaisesRegex(ValueError, "Unexpected origin"):
                dev.initialize(self.args)
            run.assert_not_called()
        self.assertFalse((self.here / ".env").exists())

    def test_invalid_paths_fail_before_clone(self):
        self.args.game_dir = str(self.root / "missing")
        with patch.object(dev, "run") as run:
            with self.assertRaisesRegex(ValueError, "Required directory"):
                dev.initialize(self.args)
            run.assert_not_called()

    def test_existing_checkouts_are_not_updated(self):
        for name in dev.REPOS:
            (self.root / name).mkdir()
        def origin(command, **kwargs):
            name = Path(command[2]).name
            return f"git@github.com:OpenCJ-org/{name}.git\n"
        with patch.object(dev.subprocess, "check_output", side_effect=origin), patch.object(dev, "run") as run:
            dev.initialize(self.args)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
