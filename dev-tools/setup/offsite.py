"""Receive another OpenCJ host's database backups into a write-only directory (run on the receiver)."""

import argparse
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import uuid

from maintenance import install_alert_unit, install_job, offsite_account, run
from operations import read_json, save_json, write_private
import sshd

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DIRECTORY = Path('/srv/opencj-offsite')
KEY_DIRECTORY = Path('/etc/ssh/opencj-authorized-keys')
SSHD_CONFIG_DIRECTORY = Path('/etc/ssh/sshd_config.d')
MAX_TOTAL_GIB = 100000
RECEIVER_SHELL = '/bin/sh'


def ensure_receiver_account(name, target):
    """A locked system account without groups, owned by this setup (marker in GECOS).

    sshd runs the key's forced rrsync command through the account's shell, so the
    shell must be /bin/sh: nologin would refuse to start rrsync. The key itself can
    run nothing but rrsync (restrict + command=), the password is locked and TTYs
    are disabled, so the shell gives no interactive access.
    """
    account = offsite_account(name)
    marker = 'OpenCJ off-site backups from ' + name
    try:
        entry = pwd.getpwnam(account)
    except KeyError:
        run(['useradd', '--system', '--user-group', '--no-create-home', '--home-dir', str(target),
             '--shell', RECEIVER_SHELL, '--comment', marker, account])
        entry = pwd.getpwnam(account)
    if entry.pw_gecos != marker or entry.pw_uid == 0:
        raise RuntimeError('Account ' + account + ' belongs to something else; preserved')
    if entry.pw_shell != RECEIVER_SHELL or entry.pw_dir != str(target):
        # An account created by an earlier version of this setup (shell nologin).
        run(['usermod', '--shell', RECEIVER_SHELL, '--home', str(target), account])
        entry = pwd.getpwnam(account)
    if os.getgrouplist(account, entry.pw_gid) != [entry.pw_gid]:
        raise RuntimeError('Receiver account has additional groups; preserved')
    status = run(['passwd', '--status', account]).split()
    if len(status) < 2 or status[1] != 'L':
        raise RuntimeError('Receiver account password is not locked')
    return entry


def restrict_receiver_ssh(account, target, public_key):
    """The key may only run rrsync in write-only mode inside target: no shell, no reading, no deleting."""
    rrsync = shutil.which('rrsync')
    if not rrsync:
        raise RuntimeError('rrsync is missing; install the rsync package (Ubuntu 22.04 or newer ships it)')
    KEY_DIRECTORY.mkdir(mode=0o755, exist_ok=True)
    # sshd reads the key as the receiving user, who must be able to enter this
    # folder; mkdir alone would leave it root-only under setup's strict umask.
    KEY_DIRECTORY.chmod(0o755)
    key_path = KEY_DIRECTORY / account
    authorized = 'restrict,command="' + rrsync + ' -wo ' + str(target) + '" ' + public_key + '\n'
    if key_path.exists() and key_path.read_text() != authorized:
        raise RuntimeError('A different key is already registered for ' + account + '; preserved')
    write_private(key_path, authorized)
    key_path.chmod(0o644)
    configuration = ('# Managed by OpenCJ setup\nMatch User ' + account + '\n'
                     '    AuthorizedKeysFile ' + str(key_path) + '\n'
                     '    AuthenticationMethods publickey\n    PasswordAuthentication no\n'
                     '    KbdInteractiveAuthentication no\n    AllowTcpForwarding no\n'
                     '    AllowStreamLocalForwarding no\n    AllowAgentForwarding no\n'
                     '    X11Forwarding no\n    PermitTTY no\nMatch all\n')
    config_path = SSHD_CONFIG_DIRECTORY / ('opencj-' + account + '.conf')
    if config_path.exists() and config_path.read_text() != configuration:
        raise RuntimeError('Existing SSH restriction differs; preserved')
    write_private(config_path, configuration)
    config_path.chmod(0o644)
    sshd.sshd('-t')
    effective = sshd.sshd('-T', '-C', 'user=' + account + ',host=localhost,addr=127.0.0.1')
    required = {'authorizedkeysfile ' + str(key_path), 'authenticationmethods publickey', 'permittty no'}
    if not required <= set(effective.splitlines()):
        raise RuntimeError('Host SSH policy overrides the required receiver restrictions')
    sshd.reload()


def receiver_storage_paths(directory):
    return Path(str(directory) + '.storage'), Path(str(directory) + '.storage.json')


def require_receiver_storage(directory):
    """Never receive or retain on the host filesystem when the bounded mount is absent."""
    image, record = receiver_storage_paths(directory)
    if not record.is_file():
        raise RuntimeError('Receiver needs bounded storage; rerun backup-receiver with an empty directory')
    storage = read_json(record)
    if storage.get('directory') != str(directory) or image.is_symlink() or not image.is_file():
        raise RuntimeError('Receiver storage ownership differs; preserved')
    if not os.path.ismount(directory):
        raise RuntimeError('Bounded receiver filesystem is not mounted; uploads and cleanup must wait')
    mounted_uuid = run(['findmnt', '-n', '-o', 'UUID', '--mountpoint', str(directory)])
    if mounted_uuid != storage['uuid'] or image.stat().st_size != storage['bytes']:
        raise RuntimeError('Receiver filesystem differs from its owned storage record')
    return storage


def prepare_receiver_storage(directory, max_gib):
    """Preallocate a dedicated ext4 filesystem: every upload, partial and kept file shares one hard limit."""
    if not re.fullmatch(r'/[A-Za-z0-9/_-]+', str(directory)) or directory == Path('/'):
        raise ValueError('Receiver directory must be an absolute path using letters, digits, /, _ and -')
    image, record = receiver_storage_paths(directory)
    capacity_bytes = max_gib * 1024 ** 3
    reserve_bytes = 2 * 1024 ** 3
    if record.exists():
        storage = read_json(record)
        if storage.get('directory') != str(directory) or storage['bytes'] != capacity_bytes:
            raise RuntimeError('Existing receiver capacity or directory differs; preserve its backups')
    else:
        if image.exists() or directory.is_symlink() or (directory.exists() and any(directory.iterdir())):
            raise RuntimeError('Receiver storage must start empty. Keep existing backups and choose a new directory.')
        directory.parent.mkdir(parents=True, exist_ok=True)
        if shutil.disk_usage(directory.parent).free < capacity_bytes + reserve_bytes:
            raise RuntimeError('Receiver needs its full capacity plus 2 GiB free; choose a smaller --max-gib')
        storage = {'directory': str(directory), 'bytes': capacity_bytes, 'uuid': str(uuid.uuid4()), 'formatted': False}
        save_json(record, storage)
    if not storage['formatted']:
        if image.is_symlink():
            raise RuntimeError('Receiver backing file is a link; preserved')
        if not image.exists():
            image.touch(mode=0o600)
        probe = subprocess.run(['blkid', '-p', '-s', 'UUID', '-o', 'value', str(image)],
                               capture_output=True, text=True, timeout=30)
        if probe.returncode not in (0, 2):
            raise RuntimeError('Cannot inspect receiver backing filesystem')
        existing_uuid = probe.stdout.strip()
        if existing_uuid and existing_uuid != storage['uuid']:
            raise RuntimeError('Receiver backing file contains another filesystem; preserved')
        if not existing_uuid:
            remaining_bytes = max(0, capacity_bytes - image.stat().st_blocks * 512)
            if shutil.disk_usage(image.parent).free < remaining_bytes + reserve_bytes:
                raise RuntimeError('Insufficient space to finish bounded receiver storage; retry after freeing space')
            run(['fallocate', '-l', str(capacity_bytes), str(image)], timeout=300)
            # nodiscard preserves the physical reservation; reserved blocks leave
            # recovery space inside the mount after an unprivileged upload fills it.
            run(['mkfs.ext4', '-q', '-F', '-E', 'nodiscard', '-m', '5', '-U', storage['uuid'], str(image)], timeout=300)
        storage['formatted'] = True
        save_json(record, storage)
    directory.mkdir(mode=0o755, exist_ok=True)
    if not os.path.ismount(directory) and any(directory.iterdir()):
        raise RuntimeError('Unmounted receiver directory contains files; preserve them before mounting')
    unit = run(['systemd-escape', '--path', '--suffix=mount', str(directory)])
    contents = ('# Managed by OpenCJ setup\n[Unit]\nDescription=Bounded OpenCJ backup storage\n'
                '[Mount]\nWhat=' + str(image) + '\nWhere=' + str(directory) + '\nType=ext4\n'
                'Options=loop,nodev,nosuid,noexec\n[Install]\nWantedBy=multi-user.target\n')
    from maintenance import managed_file
    managed_file(Path('/etc/systemd/system') / unit, contents)
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable', '--now', unit])
    require_receiver_storage(directory)


def setup_receiver(name, public_key, directory, max_gib):
    if os.geteuid() != 0:
        raise RuntimeError('Run with sudo: this creates a restricted Linux account')
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,30}', name):
        raise ValueError('Invalid sending installation name')
    if not re.fullmatch(r'ssh-ed25519 [A-Za-z0-9+/]{68}={0,2}( [A-Za-z0-9@._-]+)?', public_key):
        raise ValueError('Supply the ssh-ed25519 public key printed by the sending setup')
    if not 1 <= max_gib <= MAX_TOTAL_GIB:
        raise ValueError('max-gib must be 1-' + str(MAX_TOTAL_GIB))
    prepare_receiver_storage(directory, max_gib)
    directory.mkdir(mode=0o755, parents=True, exist_ok=True)
    # The receiving accounts must traverse the shared parent to reach their own folder.
    directory.chmod(0o755)
    target = directory / name
    target.mkdir(mode=0o700, exist_ok=True)
    entry = ensure_receiver_account(name, target)
    os.chown(target, entry.pw_uid, entry.pw_gid)
    target.chmod(0o700)
    restrict_receiver_ssh(entry.pw_name, target, public_key)
    install_alert_unit(Path('/srv/opencj'))
    # Hourly, so a new upload is out of the sender's reach soon after it arrives.
    install_job('opencj-offsite-retention', 'OpenCJ off-site backup retention', '*-*-* *:20:00',
                [ROOT / 'dev-tools/setup/maintenance.py', '--receiver-retention', directory,
                 '--max-gib', str(max_gib)], timeout_minutes=30, needs_docker=False)
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable', '--now', 'opencj-offsite-retention.timer'])
    print('Ready to receive backups from ' + name + ' as ' + entry.pw_name + ' into ' + str(target)
          + '; every hour they move to ' + str(directory / '.kept' / name) + ', out of the sender\'s reach.')
    print(f'Retention: every backup for 14 days, one per week for 8 weeks, one per month for a year,'
          f' on a preallocated {max_gib} GiB filesystem for all senders (including partial uploads).\n'
          'The newest 7 per sender are kept; when full, new uploads fail without consuming host disk space.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['backup-receiver'])
    parser.add_argument('--name', required=True, help='Name of the sending installation, for example main-eu')
    parser.add_argument('--key', required=True, help='Public key printed by the sending setup')
    parser.add_argument('--directory', type=Path, default=DEFAULT_DIRECTORY)
    parser.add_argument('--max-gib', type=int, default=50, help='Total size limit for all received backups')
    args = parser.parse_args()
    os.umask(0o077)
    setup_receiver(args.name, args.key.strip(), args.directory.resolve(), args.max_gib)


if __name__ == '__main__':
    main()
