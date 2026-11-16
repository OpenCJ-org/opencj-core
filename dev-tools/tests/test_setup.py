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
        (self.root / ".gitmodules").write_text('[submodule "cod4x-server"]\n')
        for name in dev.COMPONENTS:
            (self.root / name).mkdir()
        self.game = self.root / "game files"
        (self.game / "main").mkdir(parents=True)
        (self.game / "zone").mkdir()
        self.mod = self.root / "compiled assets"
        self.mod.mkdir()
        self.args = argparse.Namespace(
            game_dir=str(self.game),
            mod_dir=str(self.mod),
            map="mp_killhouse",
            port=28961,
            bind_ip="127.0.0.1",
        )
        for patcher in (
            patch.object(dev, "HERE", self.here),
            patch.object(dev.os, "getuid", return_value=1000, create=True),
            patch.object(dev.os, "getgid", return_value=1000, create=True),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_initializes_only_cod4_and_preserves_configuration(self):
        with patch.object(dev, "run") as run:
            dev.initialize(self.args)
        run.assert_called_once_with(
            "git", "-C", str(self.root), "submodule", "update", "--init", "--", "cod4x-server"
        )
        env = (self.here / ".env").read_text()
        config_path = self.here / "local/runtime/mods/opencj/opencj-dev.cfg"
        config = config_path.read_text()
        password = next(
            line.split("=", 1)[1].strip("'")
            for line in env.splitlines()
            if line.startswith("DB_PASSWORD=")
        )
        self.assertIn(f'set db_pass "{password}"', config)
        self.assertIn("SERVER_PORT='28961'", env)
        self.assertFalse((self.game / "mods").exists())
        with self.assertRaisesRegex(ValueError, "Already initialized"):
            dev.initialize(self.args)
        self.assertEqual(config_path.read_text(), config)
        self.assertEqual((self.here / ".env").read_text(), env)

    def test_existing_engine_work_is_preserved(self):
        engine = self.root / "cod4x-server"
        engine.mkdir()
        (engine / ".git").write_text("gitdir: ../.git/modules/cod4x-server\n")
        pending = engine / "pending.cpp"
        pending.write_text("uncommitted engine work\n")
        with patch.object(dev.subprocess, "check_output", return_value=str(engine)), patch.object(
            dev, "run"
        ) as run:
            dev.initialize(self.args)
            run.assert_not_called()
        self.assertEqual(pending.read_text(), "uncommitted engine work\n")

    def test_nonempty_engine_without_git_is_preserved(self):
        engine = self.root / "cod4x-server"
        engine.mkdir()
        (engine / "keep.txt").write_text("local work")
        with patch.object(dev, "run") as run:
            with self.assertRaisesRegex(ValueError, "not empty"):
                dev.initialize(self.args)
            run.assert_not_called()
        self.assertEqual((engine / "keep.txt").read_text(), "local work")
        self.assertFalse((self.here / ".env").exists())

    def test_missing_component_is_not_replaced_by_a_clone(self):
        (self.root / "server-gsc").rmdir()
        with patch.object(dev, "run") as run:
            with self.assertRaisesRegex(ValueError, "Missing core component"):
                dev.initialize(self.args)
            run.assert_not_called()
        self.assertFalse((self.here / ".env").exists())

    def test_invalid_paths_fail_before_submodule_initialization(self):
        self.args.game_dir = str(self.root / "missing")
        with patch.object(dev, "run") as run:
            with self.assertRaisesRegex(ValueError, "Required directory"):
                dev.initialize(self.args)
            run.assert_not_called()

    def test_component_copy_without_core_metadata_is_refused(self):
        (self.root / ".gitmodules").unlink()
        with patch.object(dev, "run") as run:
            with self.assertRaisesRegex(ValueError, "complete opencj-core"):
                dev.initialize(self.args)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
