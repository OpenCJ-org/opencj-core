"""Acquire owned CoD4 files through interactive SteamCMD in an unprivileged disposable container."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.request

from assets import COPY_CHUNK_BYTES, extract_archive, sha256_file, shared_assets_root, validate_assets
from operations import operation_lock, read_json, run, save_json
from source import copy_file

ROOT = Path(__file__).resolve().parents[2]
APP_ID = '7940'
DOWNLOAD_TIMEOUT_SECONDS = 7200
DOWNLOAD_RESERVE_BYTES = 2 * 1024 ** 3
DOWNLOAD_MAX_BYTES = 16 * 1024 ** 3
STEAM_HOME_MAX_BYTES = 2 * 1024 ** 3
BOOTSTRAP_MAX_BYTES = 64 * 1024 ** 2
# The container has no capabilities or host credentials; its private bind mounts
# are inaccessible through the root-owned staging parent on the host.
DOWNLOAD_UID = 65534
DOWNLOAD_GID = 65534
SUPPORT_PREFIX = 'cod4x_server-linux_21.2/cod4x-linux-server'
SUPPORT_FILES = ('steam_api.so', 'steamclient.so', 'main/jcod4x_00.iwd', 'main/xbase_00.iwd',
                 'zone/cod4x_patchv2.ff')


def fetch_dependency(cache, name, dependency):
    """Reuse only verified official archives; never publish an interrupted download."""
    target = cache / (name + '.archive')
    if target.exists() and sha256_file(target) == dependency['sha256']:
        return target
    temporary = cache / ('.' + name + '.partial')
    request = urllib.request.Request(dependency['url'], headers={
        'User-Agent': 'Mozilla/5.0 (compatible; OpenCJ-Setup/beta-0.1.0)'})
    deadline = time.monotonic() + 300
    try:
        with urllib.request.urlopen(request, timeout=30) as incoming, temporary.open('wb') as output:
            if not incoming.url.startswith('https://'):
                raise RuntimeError('Dependency download redirected away from HTTPS')
            size_bytes = 0
            while True:
                chunk = incoming.read(COPY_CHUNK_BYTES)
                if not chunk:
                    break
                size_bytes += len(chunk)
                if size_bytes > BOOTSTRAP_MAX_BYTES or time.monotonic() >= deadline:
                    raise RuntimeError('Dependency download exceeded its size/time limit')
                output.write(chunk)
        if sha256_file(temporary) != dependency['sha256']:
            raise RuntimeError('Dependency checksum changed; preserve setup and review the upstream release')
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def prepare_download(work):
    """Keep Valve login/cache files in a private staging directory, never in gameplay mounts."""
    dependencies = read_json(Path(__file__).with_name('steam-sources.json'))
    cache = work / 'cache'
    cache.mkdir(mode=0o700, exist_ok=True)
    archives = {name: fetch_dependency(cache, name, dependency) for name, dependency in dependencies.items()}
    home = work / 'home'
    if not (home / 'steamcmd.sh').is_file():
        stage = work / 'bootstrap'
        if stage.exists():
            shutil.rmtree(stage)
        stage.mkdir(mode=0o700)
        extract_archive(archives['steamcmd'], stage)
        for executable in ('steamcmd.sh', 'linux32/steamcmd', 'linux32/steamerrorreporter'):
            (stage / executable).chmod(0o700)
        if home.exists():
            raise RuntimeError('Incomplete SteamCMD home differs; preserve it for inspection')
        os.replace(stage, home)
    download = work / 'download'
    download.mkdir(mode=0o700, exist_ok=True)
    for directory in (home, download):
        for path in [directory, *directory.rglob('*')]:
            if not path.is_symlink():
                os.chown(path, DOWNLOAD_UID, DOWNLOAD_GID)
    return dependencies, archives, home, download


def steam_command(image, home, download, container_name, username, *, bootstrap_only=False):
    command = ['docker', 'run', '--rm', '--log-driver', 'none', '--name', container_name,
               '--user', f'{DOWNLOAD_UID}:{DOWNLOAD_GID}', '--cap-drop', 'ALL',
               '--security-opt', 'no-new-privileges:true', '--read-only', '--pids-limit', '128', '--memory', '1g',
               '--tmpfs', '/tmp:rw,nosuid,nodev,size=256m,mode=1777',
               '--mount', 'type=bind,src=' + str(home) + ',dst=/steam',
               '--mount', 'type=bind,src=' + str(download) + ',dst=/download',
               '--env', 'HOME=/steam', '--workdir', '/steam', '--entrypoint', '/bin/bash']
    if not bootstrap_only:
        command.append('-it')
    command.extend([image, '/steam/steamcmd.sh'])
    if bootstrap_only:
        command.append('+quit')
    else:
        # Valve requires force_install_dir before login. Password and Steam Guard
        # are entered only into SteamCMD's terminal, never argv, JSON or our logs.
        command.extend(['+@sSteamCmdForcePlatformType', 'windows', '+force_install_dir', '/download',
                        '+login', username, '+app_set_config', APP_ID, 'language', 'english',
                        '+app_update', APP_ID, 'validate', '+quit'])
    return command


def directory_bytes(directory):
    """Count a changing Steam tree without treating a completed temporary-file rename as failure."""
    total = 0
    for path in directory.rglob('*'):
        try:
            if path.is_file():
                total += path.stat().st_size
        except FileNotFoundError:
            continue
    return total


def download_game(image, home, download, *, bootstrap_only=False):
    """Bound the owned download process and leave resumable partial files on failure."""
    if not bootstrap_only and not sys.stdin.isatty():
        raise RuntimeError('Steam login needs an interactive terminal; rerun setup in SSH with a terminal')
    username = ''
    if not bootstrap_only:
        print('Use a Steam account owning Call of Duty 4 (2007). Enter its password and Steam Guard code only '
              'when SteamCMD asks. OpenCJ does not record this terminal session.', flush=True)
        username = input('Steam account name: ').strip()
        if not re.fullmatch(r'[A-Za-z0-9_]{1,64}', username):
            raise ValueError('Invalid Steam account name')
    if shutil.disk_usage(download).free < DOWNLOAD_RESERVE_BYTES:
        raise RuntimeError('Keep at least 2 GiB free before starting SteamCMD')
    name = 'opencj-steam-' + hashlib.sha256(str(home).encode()).hexdigest()[:16]
    existing = run(['docker', 'ps', '-aq', '--filter', 'name=^/' + name + '$'])
    if existing:
        raise RuntimeError('A previous SteamCMD container still exists; finish that download before retrying')
    command = steam_command(image, home, download, name, username, bootstrap_only=bootstrap_only)
    terminal_state = None
    if sys.stdin.isatty():
        import termios
        terminal_state = termios.tcgetattr(sys.stdin.fileno())
    process = subprocess.Popen(command)
    deadline = time.monotonic() + DOWNLOAD_TIMEOUT_SECONDS
    try:
        while process.poll() is None:
            size_bytes = directory_bytes(download)
            home_bytes = directory_bytes(home)
            at_capacity = size_bytes > DOWNLOAD_MAX_BYTES or home_bytes > STEAM_HOME_MAX_BYTES
            if at_capacity or shutil.disk_usage(download).free < DOWNLOAD_RESERVE_BYTES:
                raise RuntimeError('SteamCMD reached its download/disk-space limit; partial files kept for retry')
            if time.monotonic() >= deadline:
                raise RuntimeError('SteamCMD exceeded two hours; partial files kept for retry')
            time.sleep(2)
        if process.returncode:
            raise RuntimeError('SteamCMD failed; rerun setup to resume the download')
    finally:
        try:
            remaining = run(['docker', 'ps', '-aq', '--filter', 'name=^/' + name + '$'])
            if remaining:
                run(['docker', 'rm', '-f', remaining], timeout=30)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            if terminal_state is not None:
                termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, terminal_state)


def validate_download(download):
    """SteamCMD may exit zero on a failed app request; require its completed manifest and expected files."""
    manifest_path = download / 'steamapps' / ('appmanifest_' + APP_ID + '.acf')
    if not manifest_path.is_file():
        raise RuntimeError('Steam did not install CoD4; check account ownership and the SteamCMD error above')
    manifest = manifest_path.read_text()
    if not re.search(r'"appid"\s+"' + APP_ID + r'"', manifest) or not re.search(r'"StateFlags"\s+"4"', manifest):
        raise RuntimeError('Steam reports an incomplete CoD4 installation; rerun setup to resume')
    required = ['main/iw_' + str(index).zfill(2) + '.iwd' for index in range(14)]
    required.extend(['zone/english/common_mp.ff', 'zone/english/localized_common_mp.ff',
                     'zone/english/mp_killhouse.ff'])
    for name in required:
        if not (download / name).is_file() or not (download / name).stat().st_size:
            raise RuntimeError('Steam download is missing required game asset: ' + name)
    build = re.search(r'"buildid"\s+"([0-9]+)"', manifest)
    return build.group(1) if build else 'unknown'


def publish_game(work, target, dependencies, archives, download):
    """Publish only game assets and support files, without Steam account/cache data."""
    build_id = validate_download(download)
    stage = work / 'game-candidate'
    stage.mkdir(mode=0o755, exist_ok=True)
    support = work / 'support'
    if not support.exists():
        extracting = work / 'support-extracting'
        if extracting.exists():
            shutil.rmtree(extracting)
        extracting.mkdir()
        extract_archive(archives['cod4x-support'], extracting)
        os.replace(extracting, support)
    for folder, suffix in (('main', '.iwd'), ('zone', '.ff')):
        for path in (download / folder).rglob('*'):
            if path.is_file() and path.suffix.lower() == suffix:
                if path.is_symlink() or not path.resolve().is_relative_to(download.resolve()):
                    raise RuntimeError('Steam asset escapes its download directory')
                if shutil.disk_usage(stage).free < path.stat().st_size + DOWNLOAD_RESERVE_BYTES:
                    raise RuntimeError('Insufficient space to publish game assets; staged files kept for retry')
                copy_file(path, stage / path.relative_to(download), public=True)
    for name in SUPPORT_FILES:
        copy_file(support / SUPPORT_PREFIX / name, stage / name, public=True)
    copy_file(support / SUPPORT_PREFIX / 'readme.txt', stage / 'licenses/cod4x-support-readme.txt', public=True)
    (stage / 'usermaps').mkdir(exist_ok=True)
    validate_assets(stage, 'game')
    sources = {'steam_app': APP_ID, 'steam_build': build_id, 'platform': 'windows', 'dependencies': dependencies}
    save_json(stage / 'licenses/asset-sources.json', sources)
    for path in [stage, *stage.rglob('*')]:
        path.chmod(0o755 if path.is_dir() else 0o644)
    os.replace(stage, target)


def prepare_game_assets(instance, image, *, bootstrap_only=False):
    """Reuse accepted assets; interrupted Steam downloads remain separate from live game files."""
    if os.geteuid() != 0:
        raise RuntimeError('Run setup with sudo; SteamCMD itself runs as an unprivileged container user')
    assets = shared_assets_root(instance)
    assets.mkdir(mode=0o755, parents=True, exist_ok=True)
    assets.chmod(0o755)
    target = assets / 'game'
    work = instance.parent / '.steam-download'
    with operation_lock(instance.parent / '.steam-download.lock'):
        receipt = work / 'owner.json'
        if work.exists() and (not receipt.is_file() or read_json(receipt).get('host') != str(instance.parent)):
            raise RuntimeError('Steam staging directory belongs to another operation; preserved')
        if target.exists():
            validate_assets(target, 'game')
            if work.exists():
                shutil.rmtree(work)
            return target
        work.mkdir(mode=0o700, exist_ok=True)
        work.chmod(0o700)
        if not receipt.exists():
            save_json(receipt, {'host': str(instance.parent)})
        dependencies, archives, home, download = prepare_download(work)
        download_game(image, home, download, bootstrap_only=bootstrap_only)
        if bootstrap_only:
            return None
        publish_game(work, target, dependencies, archives, download)
        # Login tokens, Steam logs and the unused single-player content never become
        # part of the installed game tree or its migrations/backups.
        shutil.rmtree(work)
        return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-dir', type=Path, required=True)
    parser.add_argument('--image', required=True, help='Previously built OpenCJ release image')
    parser.add_argument('--bootstrap-only', action='store_true', help='Verify SteamCMD startup without account login')
    args = parser.parse_args()
    os.umask(0o077)
    instance = args.instance_dir.resolve()
    instance.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    target = prepare_game_assets(instance, args.image, bootstrap_only=args.bootstrap_only)
    print('SteamCMD bootstrap verified.' if target is None else 'Game assets installed in ' + str(target))


if __name__ == '__main__':
    main()
