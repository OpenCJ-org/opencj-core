"""Validate supplied game assets and extract bounded, checksum-verified archives."""

import hashlib
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile

# Bound imported data and metadata; larger licensed installations can use directory inputs.
MAX_ARCHIVE_BYTES = 16 * 1024 ** 3
MAX_ARCHIVE_ENTRIES = 100000
COPY_CHUNK_BYTES = 1024 * 1024


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(COPY_CHUNK_BYTES), b''):
            digest.update(chunk)
    return digest.hexdigest()


def download_archive(url, target, expected_sha256):
    """Bound download size and require a separately supplied SHA-256 before extraction."""
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or parsed.username or parsed.password:
        raise ValueError('Asset downloads require HTTPS without credentials in the URL')
    if len(expected_sha256) != 64 or any(char not in '0123456789abcdef' for char in expected_sha256):
        raise ValueError('Supply the archive SHA-256 from its trusted source')
    deadline = time.monotonic() + 1800
    request = urllib.request.Request(url, headers={'User-Agent': 'OpenCJ-Setup/beta-0.1.0'})
    with urllib.request.urlopen(request, timeout=30) as source, target.open('xb') as output:
        if urllib.parse.urlsplit(source.url).scheme != 'https':
            raise ValueError('Asset download redirected away from HTTPS')
        downloaded_bytes = 0
        while True:
            if time.monotonic() >= deadline:
                raise TimeoutError('Asset download exceeded 30 minutes')
            chunk = source.read(COPY_CHUNK_BYTES)
            if not chunk:
                break
            downloaded_bytes += len(chunk)
            if downloaded_bytes > MAX_ARCHIVE_BYTES:
                raise ValueError('Asset archive exceeds the 16 GiB download limit')
            output.write(chunk)
    if sha256_file(target) != expected_sha256:
        raise ValueError('Asset archive checksum mismatch; nothing was installed')


def extraction_target(root, name):
    """Reject traversal on POSIX and Windows-shaped archive paths alike."""
    if '\\' in name or ':' in name or name.startswith('/'):
        raise ValueError('Unsafe asset archive path')
    parts = Path(name).parts
    if '..' in parts:
        raise ValueError('Unsafe asset archive path')
    target = root.joinpath(*parts)
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError('Asset entry escapes its extraction directory')
    return target


def extract_archive(archive, destination):
    """Extract regular files/directories only; never restore archive permissions or links."""
    entries = []
    is_zip = zipfile.is_zipfile(archive)
    reader = zipfile.ZipFile(archive) if is_zip else tarfile.open(archive)
    with reader:
        members = reader.infolist() if is_zip else reader.getmembers()
        if len(members) > MAX_ARCHIVE_ENTRIES:
            raise ValueError('Too many entries in asset archive')
        total_bytes = 0
        for member in members:
            if is_zip:
                name = member.filename
                size = member.file_size
                directory = member.is_dir()
                mode = member.external_attr >> 16
                if mode & 0o170000 not in (0, 0o100000, 0o040000):
                    raise ValueError('Links and special files are not accepted in asset archives')
            else:
                name = member.name
                size = member.size
                directory = member.isdir()
                if not directory and not member.isfile():
                    raise ValueError('Links and special files are not accepted in asset archives')
            target = extraction_target(destination, name)
            total_bytes += size
            if total_bytes > MAX_ARCHIVE_BYTES:
                raise ValueError('Expanded assets exceed the 16 GiB limit')
            entries.append((member, target, directory))
        if total_bytes > shutil.disk_usage(destination).free:
            raise ValueError('Not enough disk space to extract assets')
        for member, target, directory in entries:
            if directory:
                target.mkdir(parents=True, exist_ok=True)
                target.chmod(0o755)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            for directory in [target.parent, *target.parent.parents]:
                if not directory.is_relative_to(destination):
                    break
                directory.chmod(0o755)
            source = reader.open(member) if is_zip else reader.extractfile(member)
            with source, target.open('xb') as output:
                shutil.copyfileobj(source, output, COPY_CHUNK_BYTES)
            target.chmod(0o644)


def validate_assets(directory, kind):
    if kind == 'game':
        required = ['main', 'zone', 'steamclient.so', 'steam_api.so']
        if not list((directory / 'main').glob('*.iwd')):
            raise ValueError('Game assets require main/*.iwd')
    else:
        required = ['mod.ff']
        if not list(directory.glob('*.iwd')):
            raise ValueError('Compiled OpenCJ assets require at least one IWD')
    for name in required:
        if not (directory / name).exists():
            raise ValueError(f'Missing {kind} asset: {name}')


def shared_assets_root(instance_dir):
    """One read-only copy of game files, maps and compiled mod files for every installation on a host.

    Installations live side by side in the host directory (for example /srv/opencj/main-eu),
    so the shared copy is their sibling /srv/opencj/assets.
    """
    return instance_dir.parent / 'assets'


def prepare_assets(source, kind, instance_dir, expected_sha256=''):
    """Use supplied directories read-only; publish an extracted archive only after validation."""
    supplied = Path(source).expanduser()
    if supplied.is_dir():
        directory = supplied.resolve()
        validate_assets(directory, kind)
        return directory
    assets_dir = shared_assets_root(instance_dir)
    assets_dir.mkdir(mode=0o755, exist_ok=True)
    assets_dir.chmod(0o755)
    installed = assets_dir / kind
    if installed.exists():
        validate_assets(installed, kind)
        return installed
    with tempfile.TemporaryDirectory(prefix=f'.{kind}-', dir=assets_dir) as temporary:
        stage = Path(temporary)
        archive = supplied.resolve()
        if source.startswith('https://'):
            archive = stage / 'download'
            download_archive(source, archive, expected_sha256)
        elif not archive.is_file():
            raise ValueError('Asset input must be a directory, archive, or HTTPS URL')
        elif expected_sha256 and sha256_file(archive) != expected_sha256:
            raise ValueError('Asset archive checksum mismatch')
        extracted = stage / 'files'
        extracted.mkdir()
        extract_archive(archive, extracted)
        validate_assets(extracted, kind)
        extracted.chmod(0o755)
        os.replace(extracted, installed)
    return installed
