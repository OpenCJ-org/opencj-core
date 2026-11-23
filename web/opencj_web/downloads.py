"""Copy the files of pool maps into the public download folder, and nothing else."""

import os
import re
import shutil
from dataclasses import dataclass

MAP_NAME_PATTERN = re.compile(r"[A-Za-z0-9_-]+")
# A CoD4 user map is its fastfiles plus optional IWD archives; other files in a
# map folder (sources, notes) are never published.
MAP_FILE_SUFFIXES = (".ff", ".iwd")
PARTIAL_COPY_SUFFIX = ".partial"
# Source map files are often readable by the game's group only. Published copies
# must be readable by the separate web server account.
PUBLISHED_FILE_MODE = 0o644


@dataclass(frozen=True)
class MapFile:
    name: str
    size_bytes: int


@dataclass(frozen=True)
class MapDownload:
    map_name: str
    files: tuple

    @property
    def is_available(self):
        return len(self.files) > 0

    @property
    def total_bytes(self):
        return sum(map_file.size_bytes for map_file in self.files)


def is_safe_map_name(map_name):
    """True when the name can be used as a single folder name."""
    return MAP_NAME_PATTERN.fullmatch(map_name) is not None


def _source_files(source_dir):
    if not source_dir.is_dir():
        return []
    files = []
    for entry in sorted(source_dir.iterdir()):
        if entry.is_file() and not entry.is_symlink() and entry.name.lower().endswith(MAP_FILE_SUFFIXES):
            files.append(entry)
    return files


def _is_up_to_date(source_path, target_path):
    if not target_path.is_file():
        return False
    source_stat = source_path.stat()
    target_stat = target_path.stat()
    return source_stat.st_size == target_stat.st_size and source_stat.st_mtime_ns == target_stat.st_mtime_ns


def _copy_atomically(source_path, target_path):
    # Copy beside the target, then rename, so a download never sees a half-written file.
    partial_path = target_path.with_name(target_path.name + PARTIAL_COPY_SUFFIX)
    shutil.copy2(source_path, partial_path)
    os.chmod(partial_path, PUBLISHED_FILE_MODE)
    os.replace(partial_path, target_path)


def _remove_unlisted(directory, keep_names):
    for entry in directory.iterdir():
        if entry.name in keep_names:
            continue
        if entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry)
        else:
            entry.unlink()


def sync_pool_maps(pool_map_names, usermaps_dir, downloads_dir):
    """Mirror the pool maps' files into downloads_dir and remove everything else there.

    Returns one MapDownload per pool map, in the given order. A map whose files are
    missing on disk is returned with no files. Raises ValueError for an unsafe name.
    """
    downloads_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for map_name in pool_map_names:
        if not is_safe_map_name(map_name):
            raise ValueError("Unsafe map name in pool: " + repr(map_name))
        target_dir = downloads_dir / map_name
        published_files = []
        source_files = _source_files(usermaps_dir / map_name)
        if source_files:
            target_dir.mkdir(exist_ok=True)
        for source_path in source_files:
            target_path = target_dir / source_path.name
            if not _is_up_to_date(source_path, target_path):
                _copy_atomically(source_path, target_path)
            elif (target_path.stat().st_mode & 0o777) != PUBLISHED_FILE_MODE:
                # Repairs copies made before the mode was enforced.
                os.chmod(target_path, PUBLISHED_FILE_MODE)
            published_files.append(MapFile(source_path.name, target_path.stat().st_size))
        if target_dir.is_dir():
            _remove_unlisted(target_dir, {map_file.name for map_file in published_files})
        results.append(MapDownload(map_name, tuple(published_files)))

    published_map_names = {download.map_name for download in results if download.is_available}
    _remove_unlisted(downloads_dir, published_map_names)
    return results
