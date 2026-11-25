"""Scheduled maintenance: database backups (local and off-site), pruning of abandoned runs,
a health watchdog with alerts, weekly housekeeping and Ubuntu security updates."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
import zlib
from zoneinfo import ZoneInfo

from configuration import DISCORD_WEBHOOK_GUIDE, MYSQL_IMAGE, ask, ask_int, ask_port, ask_yes_no, is_main_instance
from configuration import prompt
from configuration import validate_host, validate_port
from operations import operation_lock, read_json, run, save_json, write_private

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'server-db/tools'))
from runtime_access import quote_literal

GIB = 1024 ** 3
BACKUP_TIMEOUT_SECONDS = 1800
STREAM_CHUNK_BYTES = 64 * 1024
UNIT_MARKER = '# Managed by OpenCJ setup\n'
SYSTEMD = Path('/etc/systemd/system')
ALERT_UNIT = 'opencj-alert@.service'
COMMAND_LINK = Path('/usr/local/sbin/opencj')

# Pruning removes at most this many runs per transaction, so a player's save or
# resume waits for one short transaction at most, and at most this many batches
# per night, so a large first cleanup spreads over several quiet nights.
PRUNE_BATCH_RUNS = 200
PRUNE_MAX_BATCHES_PER_NIGHT = 500
PRUNE_PAUSE_SECONDS = 0.5
PRUNE_LOCK_WAIT_SECONDS = 10
PRUNE_MAX_MONTHS = 120

# The game healthcheck runs every 30 s and the watchdog every 2 minutes. Docker
# restarts crashed containers itself, but not hung ones; three unhealthy checks
# in a row (about 6 minutes) avoids restarting during a slow map load.
WATCHDOG_UNHEALTHY_CHECKS = 3
ALERT_REPEAT_SECONDS = 6 * 3600
DISK_ALERT_FREE_GIB = 5
ALERT_TIMEOUT_SECONDS = 10
DISCORD_MESSAGE_MAX_CHARACTERS = 1900
CRASH_LOG_LINES = 40

OFFSITE_TIMEOUT_SECONDS = 1800
OFFSITE_ACCOUNT_PREFIX = 'ocjoff_'
LINUX_USERNAME_MAX_CHARACTERS = 32
RECEIVER_MIN_KEPT_BACKUPS = 7
RECEIVER_DAILY_DAYS = 14
RECEIVER_WEEKLY_WEEKS = 8
RECEIVER_MONTHLY_MONTHS = 12
MIGRATION_BUNDLE_RETENTION_DAYS = 30
PREVIOUS_RUNTIME_RETENTION_DAYS = 30
BUILD_CACHE_RETENTION_HOURS = 168
BACKUP_NAME_PATTERN = r'\d{8}T\d{6}Z\.sql\.gz'
DISCORD_WEBHOOK_PATTERN = r'https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]{15,22}/[A-Za-z0-9_-]{20,100}'


def validate_time(time_of_day):
    calendar(time_of_day)
    return time_of_day


def calendar(time_of_day):
    if not isinstance(time_of_day, str) or not re.fullmatch(r'(?:[01][0-9]|2[0-3]):[0-5][0-9]', time_of_day):
        raise ValueError('Maintenance time must be HH:MM in Europe/Amsterdam')
    ZoneInfo('Europe/Amsterdam')
    return '*-*-* ' + time_of_day + ':00 Europe/Amsterdam'


def offsite_account(name):
    """Receiving Linux account for one sending installation (usernames are limited to 32 characters)."""
    return (OFFSITE_ACCOUNT_PREFIX + name)[:LINUX_USERNAME_MAX_CHARACTERS]


def scan_host_key(host, port):
    """Fetch the receiver's SSH host key and let the operator confirm its fingerprint once."""
    keys = run(['ssh-keyscan', '-T', '10', '-t', 'ed25519', '-p', str(port), host], timeout=30)
    if not keys:
        raise ValueError('No SSH host key received from ' + host)
    fingerprint = subprocess.run(['ssh-keygen', '-lf', '-'], input=keys.encode(), capture_output=True,
                                 timeout=10).stdout.decode().strip()
    print('Host key of ' + host + ': ' + fingerprint, flush=True)
    print('Compare it with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on that machine.', flush=True)
    if not ask_yes_no('Is this the correct fingerprint?', False):
        raise ValueError('Host key not confirmed; off-site backups were not configured')
    return keys + '\n'


def collect_offsite(name):
    if not ask_yes_no('Also copy backups to another machine (off-site)?', is_main_instance(name)):
        return {'enabled': False}
    host = ask('Off-site machine hostname', parse=validate_host)
    port = ask_port('Off-site SSH port', 22)
    return {'enabled': True, 'host': host, 'port': port,
            'user': ask('Receiving account on that machine', offsite_account(name)),
            'known_hosts': scan_host_key(host, port)}


def collect_database_maintenance(name, *, owns_database):
    """Ask the per-database questions once, on the installation that owns the database."""
    if not owns_database:
        print('Backups, pruning and IP-country updates run on the database-owning installation.', flush=True)
        return {'backups': {'enabled': False}, 'pruning': {'enabled': False}, 'geoip': {'enabled': False}}
    main = is_main_instance(name)
    backups = {'enabled': ask_yes_no('Enable automatic database backups?', main)}
    if backups['enabled']:
        backups.update(time=ask('Nightly backup time (Europe/Amsterdam)', '03:30', parse=validate_time),
                       keep=ask_int('Maximum retained backups', 7, 1, 365),
                       max_gib=ask_int('Maximum backup storage in GiB', 2, 1, 10000),
                       reserve_gib=ask_int('Minimum free disk space in GiB', 2, 1, 10000))
        backups['offsite'] = collect_offsite(name)
    months = ask_int('Delete unfinished runs not played for this many months (0 keeps them)', 6, 0, PRUNE_MAX_MONTHS)
    pruning = {'enabled': months > 0, 'months': months}
    geoip = {'enabled': ask_yes_no('Keep the IP-country data (scoreboard flags) updated automatically?', main)}
    return {'backups': backups, 'pruning': pruning, 'geoip': geoip}


def collect_updates():
    enabled = ask_yes_no('Configure automatic Ubuntu security updates?', True)
    result = {'enabled': enabled}
    if enabled:
        result['time'] = ask('Daily update time (Europe/Amsterdam)', '05:00', parse=validate_time)
        print('Some security updates (for example the kernel) only take effect after a reboot.'
              ' All OpenCJ services start again by themselves afterwards.', flush=True)
        result['reboot'] = ask_yes_no('Reboot automatically when an update requires it?', True)
        if result['reboot']:
            result['reboot_time'] = ask('Reboot check time (Europe/Amsterdam)', '05:30', parse=validate_time)
    return result


def print_webhook_help():
    print('Alerts (server crashes with their last log lines, failed backups, low disk space) can be posted'
          ' to a Discord channel. Player IP addresses and passwords are masked in posted logs.\n'
          '  1. Create a private channel that only administrators can read.\n'
          '  2. Channel settings > Integrations > Webhooks > New Webhook > Copy Webhook URL\n'
          '     (step by step: ' + DISCORD_WEBHOOK_GUIDE + ').\n'
          '  Anyone with the URL can post to that channel, so keep it private.', flush=True)


def collect_alerts():
    print_webhook_help()
    url = ask('Discord webhook URL for alerts (blank disables)', '', parse=validate_webhook)
    return {'discord_webhook': url}


def validate_webhook(url):
    if url and not re.fullmatch(DISCORD_WEBHOOK_PATTERN, url):
        raise ValueError('use a Discord webhook URL (https://discord.com/api/webhooks/...)')
    return url


def owns_database(settings):
    return settings['database']['mode'] == 'new'


def backup_policy(settings):
    default_enabled = is_main_instance(settings.get('name', '')) and owns_database(settings)
    policy = dict(settings.get('backups', {'enabled': default_enabled}))
    if type(policy.get('enabled')) is not bool:
        raise ValueError('Backup enabled setting must be Boolean')
    if not policy['enabled']:
        return {'enabled': False}
    if not owns_database(settings):
        raise ValueError('Schedule shared database backups on its owning installation')
    for field, default, maximum in [('keep', 7, 365), ('max_gib', 2, 10000), ('reserve_gib', 2, 10000)]:
        policy.setdefault(field, default)
        if type(policy[field]) is not int or not 1 <= policy[field] <= maximum:
            raise ValueError('Invalid backup limit: ' + field)
    policy.setdefault('time', '03:30')
    calendar(policy['time'])
    policy['offsite'] = offsite_policy(policy.get('offsite', {'enabled': False}))
    return policy


def offsite_policy(offsite):
    if not isinstance(offsite, dict) or type(offsite.get('enabled')) is not bool:
        raise ValueError('backups.offsite.enabled must be a Boolean')
    if not offsite['enabled']:
        return {'enabled': False}
    result = {'enabled': True, 'host': validate_host(offsite['host']), 'port': offsite.get('port', 22),
              'user': offsite['user'], 'known_hosts': offsite['known_hosts']}
    validate_port(result['port'])
    if not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', result['user']):
        raise ValueError('Invalid off-site account name')
    if not isinstance(result['known_hosts'], str) or 'ssh-' not in result['known_hosts']:
        raise ValueError('Off-site backups need the receiver host key (known_hosts line)')
    return result


def prune_policy(settings):
    policy = dict(settings.get('pruning', {'enabled': owns_database(settings), 'months': 6}))
    if type(policy.get('enabled')) is not bool:
        raise ValueError('pruning.enabled must be a Boolean')
    if not policy['enabled']:
        return {'enabled': False}
    if not owns_database(settings):
        raise ValueError('Prune a shared database on its owning installation')
    policy.setdefault('months', 6)
    policy.setdefault('time', '04:15')
    if type(policy['months']) is not int or not 1 <= policy['months'] <= PRUNE_MAX_MONTHS:
        raise ValueError('pruning.months must be 1-' + str(PRUNE_MAX_MONTHS))
    calendar(policy['time'])
    return policy


def geoip_policy(settings):
    default_enabled = is_main_instance(settings.get('name', '')) and owns_database(settings)
    policy = dict(settings.get('geoip', {'enabled': default_enabled}))
    if type(policy.get('enabled')) is not bool:
        raise ValueError('geoip.enabled must be a Boolean')
    if policy['enabled'] and not owns_database(settings):
        raise ValueError('IP-country updates run on the database-owning installation')
    return {'enabled': policy['enabled']}


def managed_file(path, contents):
    """Change only this installer's explicitly marked system configuration."""
    if path.exists() and not path.read_text().startswith(UNIT_MARKER):
        raise RuntimeError('Existing system configuration preserved: ' + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    write_private(path, UNIT_MARKER + contents)
    path.chmod(0o644)


def remove_managed_file(path):
    if path.exists():
        if not path.read_text().startswith(UNIT_MARKER):
            raise RuntimeError('Existing system configuration preserved: ' + str(path))
        path.unlink()


def systemd_argument(value):
    value = str(value)
    if any(character in value for character in '\n\r"\\%$'):
        raise ValueError('Unsupported characters for a systemd command: ' + value)
    return '"' + value + '"'


def timer_contents(schedule, service):
    return ('[Unit]\nDescription=OpenCJ scheduled maintenance\n[Timer]\nOnCalendar=' + schedule +
            '\nRandomizedDelaySec=0\nAccuracySec=1min\nPersistent=false\nUnit=' + service +
            '\n[Install]\nWantedBy=timers.target\n')


def install_job(name, description, schedule, arguments, *, timeout_minutes, needs_docker=True):
    """Install a root oneshot service plus timer; a failure triggers the alert unit.

    Most jobs need Docker access, which the game, website and other service
    identities never receive, so they run as root under a tight systemd sandbox.
    Jobs on an external backup server (needs_docker=False) must not depend on Docker,
    which that machine may not have.
    """
    command = ' '.join(systemd_argument(argument) for argument in ['/usr/bin/python3', '-B', *arguments])
    docker = 'Requires=docker.service\nAfter=docker.service\n' if needs_docker else ''
    service = ('[Unit]\nDescription=' + description + '\n' + docker +
               'OnFailure=opencj-alert@%n.service\n'
               '[Service]\nType=oneshot\nUMask=0077\nNice=10\nIOSchedulingClass=idle\n'
               'TimeoutStartSec=' + str(timeout_minutes) + 'min\nNoNewPrivileges=true\nPrivateTmp=true\n'
               'ExecStart=' + command + '\n')
    managed_file(SYSTEMD / (name + '.service'), service)
    managed_file(SYSTEMD / (name + '.timer'), timer_contents(schedule, name + '.service'))


def remove_job(name):
    if (SYSTEMD / (name + '.timer')).exists():
        run(['systemctl', 'disable', '--now', name + '.timer'])
    remove_managed_file(SYSTEMD / (name + '.timer'))
    remove_managed_file(SYSTEMD / (name + '.service'))


def install_alert_unit(host):
    executable = ROOT / 'dev-tools/setup/maintenance.py'
    # %i is the failed unit's name, substituted by systemd; it is the only unquoted part.
    command = (' '.join(systemd_argument(argument) for argument in ['/usr/bin/python3', '-B', executable])
               + ' --alert-unit %i --host-dir ' + systemd_argument(host))
    managed_file(SYSTEMD / ALERT_UNIT, '[Unit]\nDescription=OpenCJ failure alert for %i\n'
                 '[Service]\nType=oneshot\nUMask=0077\nNoNewPrivileges=true\nExecStart=' + command + '\n')


def configure_instance_jobs(instance, settings):
    """Schedule this database owner's backup and pruning jobs; remove disabled ones."""
    executable = ROOT / 'dev-tools/setup/maintenance.py'
    jobs = {
        settings['project'] + '-backup': backup_policy(settings),
        settings['project'] + '-prune': prune_policy(settings),
    }
    for name, policy in jobs.items():
        if not policy['enabled']:
            remove_job(name)
    if not any(policy['enabled'] for policy in jobs.values()):
        return
    install_alert_unit(instance.parent)
    for name, policy in jobs.items():
        if not policy['enabled']:
            continue
        if name.endswith('-backup'):
            install_job(name, 'OpenCJ database backup ' + settings['name'], calendar(policy['time']),
                        [executable, '--backup-instance', instance], timeout_minutes=65)
        else:
            install_job(name, 'OpenCJ abandoned-run pruning ' + settings['name'], calendar(policy['time']),
                        [executable, '--prune-instance', instance], timeout_minutes=120)
    run(['systemctl', 'daemon-reload'])
    for name, policy in jobs.items():
        if policy['enabled']:
            run(['systemctl', 'enable', '--now', name + '.timer'])


def install_command_link():
    """`sudo opencj <command>` from anywhere, pointing at the checkout that installed or last upgraded.

    sudo's secure_path includes /usr/local/sbin. An unrelated file with that name is left alone.
    """
    target = ROOT / 'opencj.sh'
    target.chmod(target.stat().st_mode | 0o755)
    if COMMAND_LINK.is_symlink():
        if Path(os.readlink(COMMAND_LINK)).name != 'opencj.sh':
            print('Note: ' + str(COMMAND_LINK) + ' points elsewhere; use bash opencj.sh instead.', flush=True)
            return
        COMMAND_LINK.unlink()
    elif COMMAND_LINK.exists():
        print('Note: ' + str(COMMAND_LINK) + ' already exists; use bash opencj.sh instead.', flush=True)
        return
    COMMAND_LINK.symlink_to(target)


def configure_host_jobs(host):
    """Watchdog every 2 minutes and weekly housekeeping for every installation in this host plan."""
    executable = ROOT / 'dev-tools/setup/maintenance.py'
    install_alert_unit(host)
    install_job('opencj-watchdog', 'OpenCJ health watchdog', '*:0/2',
                [executable, '--watchdog', host], timeout_minutes=5)
    install_job('opencj-housekeeping', 'OpenCJ weekly housekeeping', 'Sun *-*-* 04:30:00 Europe/Amsterdam',
                [executable, '--housekeeping', host], timeout_minutes=60)
    run(['systemctl', 'daemon-reload'])
    for name in ('opencj-watchdog', 'opencj-housekeeping'):
        run(['systemctl', 'enable', '--now', name + '.timer'])


def validate_updates(policy):
    if not isinstance(policy, dict):
        raise ValueError('Security update policy must be an object')
    result = dict(policy)
    result.setdefault('enabled', False)
    result.setdefault('reboot', True)
    for field in ('enabled', 'reboot'):
        if type(result[field]) is not bool:
            raise ValueError('Security update ' + field + ' setting must be Boolean')
    if result['enabled']:
        result.setdefault('time', '05:00')
        calendar(result['time'])
        if result['reboot']:
            result.setdefault('reboot_time', '05:30')
            calendar(result['reboot_time'])
    return result


def configure_updates(policy):
    """Apply Ubuntu's security-only policy with timers in the requested timezone."""
    policy = validate_updates(policy)
    if not policy.get('enabled', False):
        return
    schedule = calendar(policy.get('time', '05:00'))
    run(['apt-get', 'install', '-y', 'unattended-upgrades', 'tzdata'], timeout=1800)
    # Clear inherited origin lists so opting in does not silently enable all package upgrades.
    config = ('#clear Unattended-Upgrade::Allowed-Origins;\n'
              '#clear Unattended-Upgrade::Origins-Pattern;\n'
              'Unattended-Upgrade::Allowed-Origins {\n'
              '  "${distro_id}:${distro_codename}-security";\n'
              '  "${distro_id}ESMApps:${distro_codename}-apps-security";\n'
              '  "${distro_id}ESM:${distro_codename}-infra-security";\n};\n'
              'APT::Periodic::Enable "1";\nAPT::Periodic::Update-Package-Lists "1";\n'
              'APT::Periodic::Unattended-Upgrade "1";\n'
              'Unattended-Upgrade::Automatic-Reboot "false";\n')
    # apt configuration uses // comments; systemd-style ownership markers are not valid apt syntax.
    path = Path('/etc/apt/apt.conf.d/99opencj-security')
    marker = '// Managed by OpenCJ setup\n'
    if path.exists() and path.read_text() != marker + config:
        raise RuntimeError('Existing APT configuration preserved')
    write_private(path, marker + config)
    path.chmod(0o644)
    hour, minute = map(int, policy.get('time', '05:00').split(':'))
    refresh_minutes = (hour * 60 + minute - 15) % (24 * 60)
    refresh = f'{refresh_minutes // 60:02d}:{refresh_minutes % 60:02d}'
    for timer, when in [('apt-daily', calendar(refresh)), ('apt-daily-upgrade', schedule)]:
        managed_file(SYSTEMD / (timer + '.timer.d/opencj.conf'),
                     '[Timer]\nOnCalendar=\nOnCalendar=' + when +
                     '\nRandomizedDelaySec=0\nAccuracySec=1min\nPersistent=false\n')
    # Unattended-upgrades' own reboot option reboots right after installing; a separate
    # timer reboots later and only while no APT job is still running.
    if policy.get('reboot'):
        managed_file(SYSTEMD / 'opencj-security-reboot.service',
                     '[Unit]\nDescription=Reboot after security updates when required\n'
                     '[Service]\nType=oneshot\nExecCondition=/usr/bin/test -e /run/reboot-required\n'
                     'ExecCondition=/bin/sh -c "! systemctl is-active --quiet apt-daily.service apt-daily-upgrade.service"\n'
                     'ExecStart=/usr/bin/systemctl reboot\n')
        managed_file(SYSTEMD / 'opencj-security-reboot.timer',
                     timer_contents(calendar(policy.get('reboot_time', '05:30')), 'opencj-security-reboot.service'))
    run(['systemctl', 'daemon-reload'])
    for timer in ('apt-daily.timer', 'apt-daily-upgrade.timer'):
        run(['systemctl', 'enable', timer])
        run(['systemctl', 'restart', timer])
    if policy.get('reboot'):
        run(['systemctl', 'enable', '--now', 'opencj-security-reboot.timer'])


def retained_backups(directory):
    """Only installer-named regular backups participate in retention; refuse foreign contents."""
    result = []
    for path in directory.iterdir():
        if path.name == '.backup.lock':
            continue
        if path.is_symlink() or not path.is_file() or not re.fullmatch(BACKUP_NAME_PATTERN, path.name):
            raise RuntimeError('Unexpected backup directory contents; preserved')
        result.append(path)
    return sorted(result)


def prune_backups(directory, policy):
    backups = retained_backups(directory)
    count_limit = policy['keep']
    size_limit = policy['max_gib'] * GIB
    while len(backups) > 1 and (len(backups) > count_limit or sum(p.stat().st_size for p in backups) > size_limit):
        backups.pop(0).unlink()
    return sum(path.stat().st_size for path in backups)


def compress_dump(command, target, *, byte_limit, reserve_bytes, cleanup):
    """Stream within disk/time limits and stop the owned dump container on every exit."""
    deadline = time.monotonic() + BACKUP_TIMEOUT_SECONDS
    compressor = zlib.compressobj(level=6, wbits=31)
    written = 0
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    try:
        with selectors.DefaultSelector() as selector, target.open('xb') as output:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                if time.monotonic() >= deadline:
                    raise RuntimeError('Database backup exceeded its time budget')
                if not selector.select(timeout=1):
                    continue
                chunk = os.read(process.stdout.fileno(), STREAM_CHUNK_BYTES)
                compressed = compressor.compress(chunk) if chunk else compressor.flush()
                if written + len(compressed) > byte_limit:
                    raise RuntimeError('Backup storage limit reached; last successful backup preserved')
                if shutil.disk_usage(target.parent).free - len(compressed) < reserve_bytes:
                    raise RuntimeError('Backup free-space reserve reached; last successful backup preserved')
                output.write(compressed)
                written += len(compressed)
                if not chunk:
                    break
            output.flush()
            os.fsync(output.fileno())
        if process.wait(timeout=10) != 0:
            raise RuntimeError('Database dump failed; last successful backup preserved')
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        process.stdout.close()
        cleanup()


def dump_database(instance, settings, target, *, byte_limit, reserve_bytes):
    """Write a compressed, transaction-consistent dump of the owned database to target."""
    from compose_config import database_network
    from operations import inspect_container
    name = settings['project'] + '-backup-dump'
    # A killed controller may leave its dedicated dump process alive. Reuse no other container.
    existing = run(['docker', 'ps', '-aq', '--filter', 'name=^/' + name + '$'])
    if existing:
        metadata = inspect_container(existing)
        if metadata['Config']['Labels'].get('org.opencj.backup') != settings['project']:
            raise RuntimeError('Unrelated backup container preserved')
        run(['docker', 'rm', '-f', existing])
    command = ['docker', 'run', '--rm', '--log-driver', 'none', '--name', name,
               '--network', database_network(settings),
               '--label', 'org.opencj.backup=' + settings['project'], '--memory', '256m', '--pids-limit', '64',
               '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true', '--read-only',
               '--mount', 'type=bind,src=' + str(instance / 'secrets/admin.cnf') + ',dst=/run/client.cnf,readonly',
               MYSQL_IMAGE, 'timeout', '--signal=TERM', '--kill-after=10', str(BACKUP_TIMEOUT_SECONDS),
               'mysqldump', '--defaults-file=/run/client.cnf', '--single-transaction', '--quick',
               '--hex-blob', '--routines', '--triggers', '--events', '--no-tablespaces',
               '--set-gtid-purged=OFF', '--column-statistics=0', '--databases', settings['database']['name']]

    def cleanup():
        remaining = run(['docker', 'ps', '-aq', '--filter', 'name=^/' + name + '$'], timeout=30)
        if remaining:
            run(['docker', 'rm', '-f', remaining], timeout=30)

    compress_dump(command, target, byte_limit=byte_limit, reserve_bytes=reserve_bytes, cleanup=cleanup)


def run_backup(instance):
    from install import load_installation, switched_off, verify_managed_files
    from assets import sha256_file
    settings = load_installation(instance)
    policy = backup_policy(settings)
    if not policy['enabled'] or settings['state'] != 'ready':
        raise RuntimeError('Automatic backups require an enabled, ready database owner')
    if switched_off(instance, settings):
        # Nothing changes while it is off; the last backup still holds its current data.
        print(settings['name'] + ' is off (on demand); no backup needed.')
        return
    with operation_lock(instance / '.setup.lock'):
        verify_managed_files(instance, settings)
        directory = instance / 'automatic-backups'
        directory.mkdir(mode=0o700, exist_ok=True)
        temporary = instance / '.automatic-backup.partial'
        temporary.unlink(missing_ok=True)
        retained_bytes = prune_backups(directory, policy)
        backups = retained_backups(directory)
        expected_bytes = backups[-1].stat().st_size if backups else 0
        while len(backups) > 1 and retained_bytes + expected_bytes > policy['max_gib'] * GIB:
            oldest = backups.pop(0)
            retained_bytes -= oldest.stat().st_size
            oldest.unlink()
        try:
            dump_database(instance, settings, temporary, byte_limit=policy['max_gib'] * GIB - retained_bytes,
                          reserve_bytes=policy['reserve_gib'] * GIB)
            target = directory / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '.sql.gz')
            if target.exists():
                raise RuntimeError('Backup timestamp already exists; preserved')
            os.replace(temporary, target)
            prune_backups(directory, policy)
            save_json(instance / 'last-backup.json', {
                'path': str(target), 'bytes': target.stat().st_size, 'sha256': sha256_file(target),
                'scope': 'SQL schema/data/routines/triggers/events; assets and runtime are in migration exports',
            })
            print('Database backup completed: ' + target.name)
        finally:
            temporary.unlink(missing_ok=True)
    if policy['offsite']['enabled']:
        upload_offsite(instance, policy['offsite'])


def offsite_ssh_command(instance):
    return ['ssh', '-i', str(instance / 'secrets/offsite-key'), '-o', 'BatchMode=yes',
            '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'UserKnownHostsFile=' + str(instance / 'secrets/offsite-known_hosts'),
            '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30']


def prepare_offsite(instance, settings):
    """Create this installation's own upload key; print the one command for the receiver."""
    offsite = backup_policy(settings).get('offsite', {'enabled': False})
    if not offsite['enabled']:
        return
    key = instance / 'secrets/offsite-key'
    if not key.exists():
        run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', settings['project'] + '-offsite', '-f', str(key)])
    write_private(instance / 'secrets/offsite-known_hosts', offsite['known_hosts'])
    public_key = Path(str(key) + '.pub').read_text().strip()
    print('Off-site backups: on ' + offsite['host'] + ', run this once from its opencj-core checkout:', flush=True)
    print("  sudo bash opencj.sh backup-receiver --name " + settings['name'] + " --key '" + public_key + "'",
          flush=True)


def upload_offsite(instance, offsite):
    """Push retained backups; the receiver only accepts writes and keeps its own retention."""
    # The installation record is the source of truth for the receiver's host key, so
    # a key accepted again with `opencj configure` takes effect on the next upload.
    write_private(instance / 'secrets/offsite-known_hosts', offsite['known_hosts'])
    ssh = offsite_ssh_command(instance)
    ssh.extend(['-p', str(offsite['port'])])
    # Backup names are fixed timestamps, so no argument protection is needed; the
    # receiver's rrsync wrapper accepts only a plain rsync server command.
    command = ['rsync', '-rt', '--partial', '--include=*.sql.gz', '--exclude=*',
               '-e', ' '.join(ssh), str(instance / 'automatic-backups') + '/',
               offsite['user'] + '@' + offsite['host'] + ':']
    run(command, timeout=OFFSITE_TIMEOUT_SECONDS, log=instance / 'offsite.log')
    save_json(instance / 'last-offsite.json', {'host': offsite['host'],
                                               'finished': datetime.now(timezone.utc).isoformat()})
    print('Backups copied to ' + offsite['host'])


def prune_candidates(db, cutoff, limit):
    """Unfinished runs untouched since cutoff, never runs with a published or winning demo."""
    rows = db.query(
        'SELECT r.runID FROM playerRuns r '
        'WHERE r.finishcpID IS NULL AND r.finishTimeStamp IS NULL '
        'AND r.lastUsedTimeStamp < ' + quote_literal(cutoff) + ' '
        'AND NOT EXISTS (SELECT 1 FROM demoWinners w WHERE w.runID = r.runID) '
        'AND NOT EXISTS (SELECT 1 FROM demoPublications p WHERE p.runID = r.runID) '
        'ORDER BY r.runID LIMIT ' + str(limit) + ';')
    return [int(value) for value in rows.splitlines()]


def delete_runs(db, run_ids, cutoff):
    """Delete one batch of abandoned runs and their dependent rows atomically.

    The runs are locked and rechecked first: a player who resumed one since the
    candidate query keeps it, and a player resuming one now waits for this short
    transaction. Leaderboards only use finished runs, which are never selected.
    Challenge completions keep their row; the database clears their run link.
    """
    id_list = ','.join(str(run_id) for run_id in run_ids)
    db.query('START TRANSACTION;')
    confirmed = db.query(
        'SELECT runID FROM playerRuns WHERE runID IN (' + id_list + ') '
        'AND finishcpID IS NULL AND finishTimeStamp IS NULL '
        'AND lastUsedTimeStamp < ' + quote_literal(cutoff) + ' FOR UPDATE;').splitlines()
    if not confirmed:
        db.query('ROLLBACK;')
        return 0
    confirmed_list = ','.join(confirmed)
    # Children first: saves and checkpoint times reference the run without cascading;
    # demo chunks, run labels and publications cascade from their parents.
    db.query('DELETE FROM playerSaves WHERE runID IN (' + confirmed_list + ');\n'
             'DELETE FROM checkpointStatistics WHERE runID IN (' + confirmed_list + ');\n'
             'DELETE FROM demoRuns WHERE runID IN (' + confirmed_list + ');\n'
             'DELETE FROM playerRuns WHERE runID IN (' + confirmed_list + ');\n'
             'COMMIT;', timeout=PRUNE_LOCK_WAIT_SECONDS * 6)
    return len(confirmed)


def run_prune(instance):
    from install import database_client, load_installation, switched_off
    settings = load_installation(instance)
    policy = prune_policy(settings)
    if not policy['enabled'] or settings['state'] != 'ready':
        raise RuntimeError('Run pruning requires an enabled, ready database owner')
    if switched_off(instance, settings):
        print(settings['name'] + ' is off (on demand); pruning waits until it runs.')
        return
    deleted = 0
    more_remaining = False
    with database_client(instance, settings, administrator=True) as db:
        db.query('SET SESSION innodb_lock_wait_timeout=' + str(PRUNE_LOCK_WAIT_SECONDS) + ';')
        cutoff = db.query('SELECT NOW() - INTERVAL ' + str(policy['months']) + ' MONTH;')
        for batch in range(PRUNE_MAX_BATCHES_PER_NIGHT):
            candidates = prune_candidates(db, cutoff, PRUNE_BATCH_RUNS)
            if not candidates:
                break
            deleted += delete_runs(db, candidates, cutoff)
            time.sleep(PRUNE_PAUSE_SECONDS)
        else:
            more_remaining = bool(prune_candidates(db, cutoff, 1))
    save_json(instance / 'last-prune.json', {
        'finished': datetime.now(timezone.utc).isoformat(), 'cutoff': cutoff,
        'runs_deleted': deleted, 'more_remaining': more_remaining})
    print(f'Deleted {deleted} unfinished runs not played since {cutoff}'
          + ('; more remain for the next night' if more_remaining else ''))


def host_plan(host):
    plan = read_json(host / 'host-setup.json')
    if plan.get('host_dir') != str(host):
        raise RuntimeError('Host plan belongs to another directory')
    return plan


def alert_webhook(host):
    """The game host's alert webhook, or on an external backup server the outside check's one."""
    for path, keys in ((host / 'host-setup.json', ('alerts', 'discord_webhook')),
                       (host / 'remote-monitor.json', ('webhook',))):
        try:
            value = read_json(path)
        except (OSError, ValueError):
            continue
        for key in keys:
            value = value.get(key, '') if isinstance(value, dict) else ''
        if value:
            return value
    return ''


def send_alert(host, message):
    """Post to the configured Discord webhook; always also print to the systemd journal."""
    send_webhook(alert_webhook(host), '[OpenCJ ' + socket.gethostname() + '] ' + message)


def send_webhook(webhook, text):
    """Print text to the journal and, when a webhook is set, post it there (mentions disabled)."""
    print(text, flush=True)
    if not webhook:
        return
    body = json.dumps({'content': text[:DISCORD_MESSAGE_MAX_CHARACTERS],
                       'allowed_mentions': {'parse': []}}).encode()
    request = urllib.request.Request(webhook, data=body, method='POST', headers={
        'Content-Type': 'application/json', 'User-Agent': 'OpenCJ-Setup'})
    with urllib.request.urlopen(request, timeout=ALERT_TIMEOUT_SECONDS):
        pass


def alert_for_failed_unit(host, unit):
    if not re.fullmatch(r'[A-Za-z0-9@._-]+', unit):
        raise ValueError('Invalid unit name')
    send_alert(host, 'Scheduled job failed: ' + unit + '. Inspect it with: journalctl -u ' + unit + ' -n 50')


def ready_installations(host):
    """Yield (name, directory, settings) for each completed installation in the host plan."""
    from install import load_installation
    for name in host_plan(host).get('completed', []):
        instance = host / name
        settings = load_installation(instance, allow_other_release=True)
        if settings.get('state') == 'ready':
            yield name, instance, settings


def should_repeat_alert(state, key):
    now = time.time()
    if now - state.get('alerted', {}).get(key, 0) < ALERT_REPEAT_SECONDS:
        return False
    state.setdefault('alerted', {})[key] = now
    return True


def redact_log(text, settings):
    """Mask player IP addresses and this installation's secrets before a log leaves the machine."""
    for secret in (settings.get('join_password'), settings.get('rcon_password'),
                   settings.get('database', {}).get('password')):
        if secret:
            text = text.replace(secret, '[secret]')
    text = re.sub(r'\b\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?\b', '[ip]', text)
    return re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', text)


def report_crash_restart(host, state, name, settings, metadata):
    """Docker restarts a crashed game server by itself; tell the operators, with the last log lines."""
    container = metadata['Id']
    restarts = state.setdefault('restart_counts', {})
    previous = restarts.get(container)
    current = metadata.get('RestartCount', 0)
    restarts[container] = current
    if previous is None or current <= previous:
        return
    # Lines up to the current start belong to the run that crashed.
    result = subprocess.run(['docker', 'logs', '--until', metadata['State']['StartedAt'], '--tail',
                             str(CRASH_LOG_LINES), container], capture_output=True, timeout=60)
    log = redact_log((result.stdout + result.stderr).decode(errors='replace'), settings)
    exit_code = metadata['State'].get('ExitCode')
    header = (name + ': the game server crashed and was restarted automatically'
              + ('' if exit_code is None else ' (exit code ' + str(exit_code) + ')') + '. Last log lines:\n')
    budget = DISCORD_MESSAGE_MAX_CHARACTERS - len(header) - 60
    send_alert(host, header + '```\n' + log[-budget:] + '\n```')


def check_optional_services(host, state, name, instance, settings):
    """Report a Discord bridge or GeoIP updater stuck in a restart loop (for example a wrong token)."""
    from install import compose, optional_services
    from operations import inspect_container
    for service in optional_services(settings):
        container = compose(instance, settings, 'ps', '--all', '--quiet', service)
        if not container:
            continue
        status = inspect_container(container)['State']
        if status.get('Restarting') or not status['Running']:
            if should_repeat_alert(state, name + ':' + service):
                send_alert(host, name + ': the ' + service + ' service keeps stopping. Inspect it with:'
                           ' docker logs --tail 30 ' + container[:12])


def run_watchdog(host):
    """Restart hung game servers and report problems that need an operator."""
    from install import compose
    from operations import inspect_container
    state_path = host / 'watchdog-state.json'
    state = read_json(state_path) if state_path.exists() else {}
    unhealthy = state.setdefault('unhealthy', {})
    for name, instance, settings in ready_installations(host):
        container = compose(instance, settings, 'ps', '--all', '--quiet', 'server')
        if not container:
            if should_repeat_alert(state, name + ':missing'):
                send_alert(host, name + ': the game server container is missing.')
            continue
        metadata = inspect_container(container)
        status = metadata['State']
        if settings.get('on_demand') and not status['Running'] and not status.get('Restarting'):
            # Switched off with `opencj stop`; Docker restarts crashes itself.
            continue
        check_optional_services(host, state, name, instance, settings)
        report_crash_restart(host, state, name, settings, metadata)
        if not status['Running']:
            # Docker restarts crashes itself; a stopped container was stopped on purpose.
            if should_repeat_alert(state, name + ':stopped'):
                send_alert(host, name + ': the game server is stopped.')
            continue
        if status.get('Health', {}).get('Status') != 'unhealthy':
            unhealthy[name] = 0
            continue
        unhealthy[name] = unhealthy.get(name, 0) + 1
        if unhealthy[name] >= WATCHDOG_UNHEALTHY_CHECKS:
            run(['docker', 'restart', '--time', '30', container], timeout=90)
            unhealthy[name] = 0
            send_alert(host, name + ': the game server stopped answering and was restarted.')
    free_gib = shutil.disk_usage(host).free / GIB
    if free_gib < DISK_ALERT_FREE_GIB and should_repeat_alert(state, 'disk'):
        send_alert(host, f'Only {free_gib:.1f} GiB of disk space is left.')
    # Recreated containers get new IDs; forget counters of containers that no longer exist.
    existing = set(run(['docker', 'ps', '-aq', '--no-trunc']).splitlines())
    state['restart_counts'] = {container: count for container, count in state.get('restart_counts', {}).items()
                               if container in existing}
    save_json(state_path, state)


def current_images(host):
    """Image names that installed services use now; housekeeping never removes them."""
    images = set()
    for name, instance, settings in ready_installations(host):
        images.add(settings['image'])
        if settings.get('website'):
            images.add(settings['project'] + '-web:' + settings['release'])
        for key in ('discord_image', 'geoip_image'):
            if settings.get(key):
                images.add(settings[key])
    return images


def remove_old_release_images(host):
    """Remove earlier releases of this host's own images once no container uses them."""
    projects = set()
    releases = set()
    for name, instance, settings in ready_installations(host):
        projects.add(settings['project'])
        releases.add(settings['release'])
    keep = current_images(host)
    # The engine builder image is shared by all servers; keep the one for each release in use.
    keep.update('opencj-builder:' + release for release in releases)
    listing = run(['docker', 'image', 'ls', '--format', '{{.Repository}}:{{.Tag}}'])
    for image in listing.splitlines():
        repository = image.rsplit(':', 1)[0]
        owned = any(repository == project or repository.startswith(project + '-') for project in projects)
        owned = owned or repository == 'opencj-builder'
        if owned and image not in keep:
            # docker refuses to remove an image a container still uses; that is the intended guard.
            subprocess.run(['docker', 'image', 'rm', image], capture_output=True, timeout=120)


def remove_expired(paths, retention_days):
    deadline = time.time() - retention_days * 86400
    for path in paths:
        if path.exists() and path.stat().st_mtime < deadline:
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()


def run_housekeeping(host):
    """Weekly cleanup of data that only grows: old images, build cache, package cache, stale copies."""
    remove_old_release_images(host)
    run(['docker', 'image', 'prune', '-f'], timeout=600)
    run(['docker', 'builder', 'prune', '-f', '--filter', 'until=' + str(BUILD_CACHE_RETENTION_HOURS) + 'h'],
        timeout=600)
    run(['apt-get', 'autoclean', '-y'], timeout=600)
    for name, instance, settings in ready_installations(host):
        # The verified migration copy holds player data and is no longer needed
        # once the installation has run for a while; its assets were moved out.
        if settings.get('migration', {}).get('database_restored'):
            remove_expired([instance / 'migration/bundle'], MIGRATION_BUNDLE_RETENTION_DAYS)
        remove_expired(sorted(instance.glob('runtime.previous-*')), PREVIOUS_RUNTIME_RETENTION_DAYS)
    print('Housekeeping completed.')


def backup_time(path):
    # Names are YYYYMMDDTHHMMSSZ.sql.gz; the first 15 characters are the UTC time.
    return datetime.strptime(path.name[:15], '%Y%m%dT%H%M%S').replace(tzinfo=timezone.utc)


def tiered_backups_to_keep(backups, now):
    """Grandfather-father-son retention: every recent backup, then the newest per week, then per month.

    backups is sorted oldest first. The newest few are always kept, even when old,
    so a sender that stopped long ago still has its last state.
    """
    keep = set(backups[-RECEIVER_MIN_KEPT_BACKUPS:])
    weeks_kept = set()
    months_kept = set()
    for path in reversed(backups):
        created = backup_time(path)
        age_days = (now - created).total_seconds() / 86400
        if age_days <= RECEIVER_DAILY_DAYS:
            keep.add(path)
        elif age_days <= RECEIVER_WEEKLY_WEEKS * 7:
            week = created.isocalendar()[:2]
            if week not in weeks_kept:
                weeks_kept.add(week)
                keep.add(path)
        elif age_days <= RECEIVER_MONTHLY_MONTHS * 31:
            month = (created.year, created.month)
            if month not in months_kept:
                months_kept.add(month)
                keep.add(path)
    return keep


def run_receiver_retention(directory, max_gib):
    """On the off-site receiver: apply tiered retention per sender, then a total size cap.

    The cap deletes the oldest remaining backups across all senders, never a
    sender's newest few, so one oversized backup cannot erase recent history.
    """
    now = datetime.now(timezone.utc)
    kept = []
    protected = set()
    for sender in sorted(path for path in directory.iterdir() if path.is_dir()):
        backups = sorted(path for path in sender.iterdir()
                         if path.is_file() and re.fullmatch(BACKUP_NAME_PATTERN, path.name))
        keep = tiered_backups_to_keep(backups, now)
        for path in backups:
            if path not in keep:
                path.unlink()
        kept.extend(keep)
        protected.update(backups[-RECEIVER_MIN_KEPT_BACKUPS:])
    kept.sort(key=backup_time)
    total_bytes = sum(path.stat().st_size for path in kept)
    for path in list(kept):
        if total_bytes <= max_gib * GIB:
            break
        if path in protected:
            continue
        total_bytes -= path.stat().st_size
        path.unlink()
    if total_bytes > max_gib * GIB:
        print(f'Warning: the newest backups alone use {total_bytes / GIB:.1f} GiB, above the {max_gib} GiB cap.')
    print(f'Off-site backups use {total_bytes / GIB:.2f} GiB of {max_gib} GiB.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument('--backup-instance', type=Path)
    actions.add_argument('--prune-instance', type=Path)
    actions.add_argument('--watchdog', type=Path, metavar='HOST_DIR')
    actions.add_argument('--housekeeping', type=Path, metavar='HOST_DIR')
    actions.add_argument('--alert-unit')
    actions.add_argument('--receiver-retention', type=Path, metavar='RECEIVE_DIR')
    parser.add_argument('--host-dir', type=Path, default=Path('/srv/opencj'))
    parser.add_argument('--max-gib', type=int, default=50)
    args = parser.parse_args()
    os.umask(0o077)
    if args.backup_instance:
        run_backup(args.backup_instance.resolve())
    elif args.prune_instance:
        run_prune(args.prune_instance.resolve())
    elif args.watchdog:
        run_watchdog(args.watchdog.resolve())
    elif args.housekeeping:
        run_housekeeping(args.housekeeping.resolve())
    elif args.alert_unit:
        alert_for_failed_unit(args.host_dir.resolve(), args.alert_unit)
    else:
        run_receiver_retention(args.receiver_retention.resolve(), args.max_gib)


if __name__ == '__main__':
    main()
