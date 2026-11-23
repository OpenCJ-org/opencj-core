#!/usr/bin/env python3
"""List reviewed test groups or run the portable checks without application services."""

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
CATALOGUE = "dev-tools/tests/catalogue.json"
CATEGORIES = {"portable", "integration", "manual", "support"}


def test_files(root):
    """Use Git's inventory so ignored local experiments never become test inputs."""
    result = subprocess.run(
        ["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        check=True,
        capture_output=True,
        text=True,
    )
    files = set()
    for name in result.stdout.split("\0"):
        path = PurePosixPath(name)
        if not (root / name).is_file():
            continue
        if name.startswith("dev-tools/tests/"):
            if path.suffix != ".md" and name != CATALOGUE:
                files.add(name)
        elif path.name.startswith("test_") and path.suffix == ".py":
            files.add(name)
    return files


def load_catalogue(root=ROOT):
    catalogue = json.loads((root / CATALOGUE).read_text())
    if catalogue.get("version") != 1 or not isinstance(catalogue.get("groups"), list):
        raise ValueError("Unsupported test catalogue format")
    groups = catalogue["groups"]
    identifiers = set()
    listed_files = set()
    for group in groups:
        identifier = group.get("id", "")
        if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", identifier):
            raise ValueError("Invalid test group identifier")
        if identifier in identifiers:
            raise ValueError("Duplicate test group: " + identifier)
        identifiers.add(identifier)
        if group.get("category") not in CATEGORIES:
            raise ValueError("Invalid category: " + identifier)
        for field in ("description", "requires", "effects"):
            if not isinstance(group.get(field), str) or not group[field].strip():
                raise ValueError(identifier + ": missing " + field)
        if not isinstance(group.get("commands"), list):
            raise ValueError(identifier + ": commands must be a list")
        if not all(isinstance(command, str) and command.strip() for command in group["commands"]):
            raise ValueError(identifier + ": invalid command")
        if not isinstance(group.get("files"), list) or not group["files"]:
            raise ValueError(identifier + ": no test files")
        for name in group["files"]:
            path = PurePosixPath(name)
            if path.is_absolute() or ".." in path.parts or "\\" in name:
                raise ValueError("Test path must stay inside the repository: " + name)
            if not (root / name).resolve().is_relative_to(root.resolve()):
                raise ValueError("Test path resolves outside the repository: " + name)
            if not (root / name).is_file():
                raise ValueError("Missing test file: " + name)
            if name in listed_files:
                raise ValueError("Test file listed twice: " + name)
            listed_files.add(name)
        if group["category"] == "portable":
            if group.get("mode") not in {"unit", "script"}:
                raise ValueError(identifier + ": portable mode must be unit or script")
            if any(not name.endswith(".py") for name in group["files"]):
                raise ValueError(identifier + ": portable entry points must be Python files")
        elif "mode" in group:
            raise ValueError(identifier + ": only portable groups can be executed here")
        elif group["category"] != "support" and not group["commands"]:
            raise ValueError(identifier + ": no maintained command")
    inventory = test_files(root)
    if listed_files != inventory:
        missing = sorted(inventory - listed_files)
        extra = sorted(listed_files - inventory)
        raise ValueError(
            "Catalogue mismatch; unlisted=" + repr(missing) + "; unexpected=" + repr(extra)
        )
    if not any(group["category"] == "portable" for group in groups):
        raise ValueError("No portable test groups")
    return groups


def select_portable(groups, requested):
    by_id = {group["id"]: group for group in groups}
    selected = []
    for identifier in requested:
        if identifier not in by_id:
            raise ValueError("Unknown test group: " + identifier)
        if by_id[identifier]["category"] != "portable":
            raise ValueError(
                "Group requires its explicit integration/manual command: " + identifier
            )
        selected.append(by_id[identifier])
    if not requested:
        selected = [group for group in groups if group["category"] == "portable"]
    return selected


def run_unit(path):
    # Each file gets a fresh interpreter, avoiding import-name collisions between components.
    suite = unittest.TestLoader().discover(str(path.parent), pattern=path.name)
    if suite.countTestCases() == 0:
        raise ValueError("No unit tests discovered in " + path.name)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result.skipped:
        print("Incomplete unit run: skipped tests are not a full pass.", file=sys.stderr)
    return 0 if result.wasSuccessful() and not result.skipped else 1


def run_portable(groups, root=ROOT):
    for group in groups:
        print("\n== " + group["id"] + " ==", flush=True)
        for name in group["files"]:
            if group["mode"] == "unit":
                command = [sys.executable, "-B", str(Path(__file__).resolve()), "_unit", name]
            else:
                command = [sys.executable, "-B", str(root / name)]
            result = subprocess.run(command, cwd=root)
            if result.returncode:
                print("FAILED: " + name, file=sys.stderr)
                return 1
    print("\nPortable checks passed. Engine, database and compiled-client suites were not run.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser(
        "list", help="List groups; optionally show full details for one group"
    )
    listing.add_argument("group", nargs="?")
    commands.add_parser("check", help="Verify every test file has a maintained catalogue entry")
    portable = commands.add_parser("portable", help="Run the reviewed offline checks")
    portable.add_argument("groups", nargs="*")
    unit = commands.add_parser("_unit", help=argparse.SUPPRESS)
    unit.add_argument("file")
    options = parser.parse_args()
    try:
        groups = load_catalogue()
        if options.command == "check":
            print("Catalogue valid: " + str(len(groups)) + " groups.")
        elif options.command == "list":
            if options.group:
                group = next((item for item in groups if item["id"] == options.group), None)
                if group is None:
                    raise ValueError("Unknown test group: " + options.group)
                print(json.dumps(group, indent=2))
            else:
                for group in groups:
                    print(group["id"] + " [" + group["category"] + "] " + group["description"])
        elif options.command == "_unit":
            allowed_unit_files = set()
            for group in groups:
                if group.get("mode") == "unit":
                    allowed_unit_files.update(group["files"])
            if options.file not in allowed_unit_files:
                raise ValueError("Not a reviewed unit-test entry point: " + options.file)
            return run_unit(ROOT / options.file)
        else:
            return run_portable(select_portable(groups, options.groups))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print("Test discovery failed: " + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
