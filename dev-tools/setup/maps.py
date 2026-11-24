"""Add, update and list custom maps in the host's shared map folder (usermaps)."""

import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shutil
import tempfile

from assets import download_archive, extract_archive, sha256_file
from operations import read_json

MAP_NAME_PATTERN = r'[a-z0-9_]{1,64}'
# The game loads <map>.ff (and optionally <map>_load.ff and .iwd files); the website
# only publishes these two file types, so nothing else belongs in a map folder.
MAP_FILE_SUFFIXES = ('.ff', '.iwd')


def host_usermaps(host):
    """The usermaps folder every installation in this host plan reads."""
    plan = read_json(host / 'host-setup.json')
    game_dirs = set()
    for name in plan.get('completed', []):
        settings = read_json(host / name / 'installation.json')
        game_dirs.add(settings['game_dir'])
    if len(game_dirs) != 1:
        raise RuntimeError('Expected all installations to share one game folder; found ' + str(len(game_dirs)))
    usermaps = Path(game_dirs.pop()) / 'usermaps'
    usermaps.mkdir(mode=0o755, exist_ok=True)
    return usermaps


def find_map_folder(staged):
    """Accept the map files directly, or one folder named after the map."""
    entries = [path for path in staged.iterdir() if not path.name.startswith('.')]
    if len(entries) == 1 and entries[0].is_dir():
        return entries[0], entries[0].name
    names = {path.name.rsplit('.', 1)[0] for path in entries if path.suffix == '.ff'}
    names = {name for name in names if not name.endswith('_load')}
    if len(names) != 1:
        raise ValueError('Supply one map: a folder <map>/ or the files <map>.ff (+ <map>_load.ff, <map>.iwd)')
    return staged, names.pop()


def validate_map(folder, name):
    if not re.fullmatch(MAP_NAME_PATTERN, name):
        raise ValueError('Map names use lowercase letters, digits and underscores: ' + name)
    files = list(folder.iterdir())
    for path in files:
        if path.is_symlink() or not path.is_file() or path.suffix not in MAP_FILE_SUFFIXES:
            raise ValueError('Unexpected file in map folder (only .ff and .iwd): ' + path.name)
    if not (folder / (name + '.ff')).is_file():
        raise ValueError('Map ' + name + ' needs ' + name + '.ff')
    return files


def stage_source(source, staging, expected_sha256):
    supplied = Path(source).expanduser()
    if supplied.is_dir():
        destination = staging / supplied.name
        shutil.copytree(supplied, destination, symlinks=True)
        return
    archive = supplied
    if source.startswith('https://'):
        archive = staging.parent / (staging.name + '.download')
        download_archive(source, archive, expected_sha256)
    elif not supplied.is_file():
        raise ValueError('Map source must be a folder, an archive or an https:// URL')
    elif expected_sha256 and sha256_file(supplied) != expected_sha256:
        raise ValueError('Map archive checksum mismatch')
    try:
        extract_archive(archive, staging)
    finally:
        if archive != supplied:
            archive.unlink(missing_ok=True)


def add_map(host, source, expected_sha256=''):
    """Install or replace one map atomically: servers never see a half-copied folder."""
    usermaps = host_usermaps(host)
    with tempfile.TemporaryDirectory(prefix='.map-', dir=usermaps) as temporary:
        staging = Path(temporary) / 'source'
        staging.mkdir()
        stage_source(source, staging, expected_sha256)
        folder, name = find_map_folder(staging)
        validate_map(folder, name)
        for path in [folder, *folder.iterdir()]:
            path.chmod(0o755 if path.is_dir() else 0o644)
        target = usermaps / name
        replaced = None
        if target.exists():
            stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
            replaced = Path(temporary) / ('previous-' + stamp)
            os.replace(target, replaced)
        os.replace(folder, target)
    action = 'Updated' if replaced else 'Added'
    print(action + ' map ' + name + ' in ' + str(target) + '.')
    print('Servers load it on the next map change. To offer it on a server, add it to that'
          ' server\'s map pool in the game.')


def list_maps(host):
    usermaps = host_usermaps(host)
    for folder in sorted(path for path in usermaps.iterdir() if path.is_dir() and not path.name.startswith('.')):
        size_bytes = sum(path.stat().st_size for path in folder.iterdir() if path.is_file())
        print(f'{folder.name:40} {size_bytes / 1024 ** 2:8.1f} MiB')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['maps'])
    parser.add_argument('--host-dir', type=Path, default=Path('/srv/opencj'))
    actions = parser.add_subparsers(dest='action', required=True)
    add = actions.add_parser('add', help='Add or replace a map from a folder, archive or https:// URL')
    add.add_argument('source')
    add.add_argument('--sha256', default='', help='Required for https:// downloads')
    actions.add_parser('list')
    args = parser.parse_args()
    os.umask(0o022)
    host = args.host_dir.resolve()
    if args.action == 'add':
        add_map(host, args.source, args.sha256)
    else:
        list_maps(host)


if __name__ == '__main__':
    main()
