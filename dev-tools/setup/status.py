"""`opencj status`: one overview of everything on this machine, ending with what needs attention.

Every check reads only (Docker, systemd, receipts, a local TLS handshake, DNS); nothing is
changed. A line that needs the operator is also collected in the closing attention list,
so a weekly glance at the end of the output is enough.
"""

from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil
import socket
import ssl
import subprocess
import time

import dns_guide
import install
import maintenance
from operations import read_json
import source as source_export
import website as managed_website

SYSTEMD = Path('/etc/systemd/system')
REBOOT_REQUIRED = Path('/run/reboot-required')
COMMAND_TIMEOUT_SECONDS = 60
TLS_TIMEOUT_SECONDS = 5
# Caddy renews about 30 days before expiry; under 14 days left means renewal is failing.
CERTIFICATE_MIN_DAYS = 14
HOUR = 3600
# How old a job's last run may be before it counts as not running (a bit over its interval).
JOB_MAX_AGE_SECONDS = {'watchdog': 10 * 60, 'outside check': 10 * 60, 'housekeeping': 8 * 24 * HOUR,
                       'backup': 26 * HOUR, 'pruning': 26 * HOUR, 'received-backup cleanup': 26 * HOUR}
RECEIPT_MAX_AGE_SECONDS = 26 * HOUR


class Report:
    """Collects the lines that need the operator; everything else is only printed."""

    def __init__(self):
        self.attention = []

    def check(self, ok, problem):
        """Return 'OK' or 'PROBLEM', remembering the problem text for the closing list."""
        if ok:
            return 'OK'
        self.attention.append(problem)
        return 'PROBLEM'


def quiet(arguments):
    """Output of a read-only command, or '' when it fails (for example a tool that is not installed)."""
    try:
        return subprocess.run(arguments, capture_output=True, text=True, timeout=COMMAND_TIMEOUT_SECONDS).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ''


def age_text(seconds):
    if seconds < 2 * 60:
        return 'just now'
    if seconds < 2 * HOUR:
        return f'{seconds / 60:.0f} min ago'
    if seconds < 48 * HOUR:
        return f'{seconds / HOUR:.0f} h ago'
    return f'{seconds / 86400:.0f} days ago'


def compose_rows(arguments):
    """Rows of `docker compose ps --all --format json` (one object per line, or one array)."""
    text = quiet([*arguments, 'ps', '--all', '--format', 'json']).strip()
    if not text:
        return []
    if text.startswith('['):
        return json.loads(text)
    return [json.loads(line) for line in text.splitlines() if line.strip()]


def service_summary(expected, rows):
    """('server healthy · db healthy · discord running', [problems]) for one Compose project."""
    by_service = {row.get('Service'): row for row in rows}
    parts = []
    problems = []
    for service in expected:
        row = by_service.get(service)
        if row is None:
            parts.append(service + ' missing')
            problems.append(service + ' is missing')
            continue
        state = row.get('State', '?')
        health = row.get('Health', '')
        if state != 'running':
            parts.append(service + ' ' + state)
            problems.append(service + ' is ' + state)
        elif health and health != 'healthy':
            parts.append(service + ' ' + health)
            if health != 'starting':
                problems.append(service + ' is ' + health)
        else:
            parts.append(service + ' ' + (health or 'running'))
    return ' · '.join(parts), problems


def expected_services(compose_file):
    return list(read_json(compose_file).get('services', {}))


def certificate_summary(certificate, now):
    """(text, problem or None) for a verified certificate's expiry."""
    days_left = (ssl.cert_time_to_seconds(certificate['notAfter']) - now) / 86400
    text = f'certificate valid, {days_left:.0f} days left'
    if days_left < CERTIFICATE_MIN_DAYS:
        return text, 'renewal seems to fail'
    return text, None


def check_certificate(domain, now, address='127.0.0.1'):
    """Ask the local HTTPS proxy for this domain's certificate and verify it like a browser would.

    Connecting to this machine itself (with the domain as the requested name) checks
    the certificate Caddy actually serves, whatever DNS currently says.
    """
    context = ssl.create_default_context()
    try:
        with socket.create_connection((address, 443), timeout=TLS_TIMEOUT_SECONDS) as connection:
            with context.wrap_socket(connection, server_hostname=domain) as secured:
                return certificate_summary(secured.getpeercert(), now)
    except ssl.SSLCertVerificationError as error:
        return 'no valid certificate (' + str(error.verify_message) + ')', 'no valid HTTPS certificate yet'
    except OSError as error:
        return 'HTTPS not answering (' + str(error) + ')', 'HTTPS is not answering'


def unit_object_path(unit):
    """systemd's D-Bus object path: every character except letters and digits becomes _xx."""
    return '/org/freedesktop/systemd1/unit/' + ''.join(
        character if character.isascii() and character.isalnum() else '_%02x' % ord(character) for character in unit)


def unit_property(unit, interface, name):
    """One raw property over D-Bus ('t 1795582850930867' -> '1795582850930867', 's "active"' -> 'active').

    `systemctl show` prints times in the local, human format whatever options are
    given; D-Bus returns them as plain microseconds.
    """
    output = quiet(['busctl', 'get-property', 'org.freedesktop.systemd1', unit_object_path(unit),
                    'org.freedesktop.systemd1.' + interface, name]).strip()
    kind, _, value = output.partition(' ')
    return value.strip('"') if kind in ('s', 't') else ''


def timer_properties(timer):
    """ActiveState and LastTriggerUSec ('@seconds', or '' when it never ran) of a timer unit."""
    microseconds = unit_property(timer + '.timer', 'Timer', 'LastTriggerUSec')
    last = int(microseconds) // 1_000_000 if microseconds.isdigit() and int(microseconds) else None
    return {'ActiveState': unit_property(timer + '.timer', 'Unit', 'ActiveState') or 'missing',
            'LastTriggerUSec': '@' + str(last) if last else ''}


def unix_time(value):
    """systemd's '@1732540000' (or '' / 'n/a' for never) as seconds."""
    match = re.fullmatch(r'@(\d+)', value or '')
    return int(match.group(1)) if match else None


def job_summary(label, timer, service, now):
    """(text, problem or None) for one scheduled job from its timer and service properties."""
    if timer.get('ActiveState') != 'active':
        return 'timer ' + timer.get('ActiveState', 'missing'), 'its timer is not active'
    last = unix_time(timer.get('LastTriggerUSec'))
    if last is None:
        return 'not run yet', None
    text = 'ran ' + age_text(now - last)
    if service.get('Result', 'success') != 'success':
        return text + ', FAILED (' + service['Result'] + ')', 'its last run failed'
    max_age = next((seconds for key, seconds in JOB_MAX_AGE_SECONDS.items() if label.endswith(key)), None)
    if max_age and now - last > max_age:
        return text, 'it has not run for ' + age_text(now - last).removesuffix(' ago')
    return text + ', OK', None


def job_label(timer_name, projects):
    """Readable name for a managed timer, for example 'main-eu backup'."""
    labels = {'opencj-watchdog': 'watchdog', 'opencj-housekeeping': 'housekeeping',
              'opencj-security-reboot': 'reboot after updates', 'opencj-remote-monitor': 'outside check',
              'opencj-offsite-retention': 'received-backup cleanup'}
    if timer_name in labels:
        return labels[timer_name]
    for project, name in projects.items():
        for suffix, word in (('-backup', 'backup'), ('-prune', 'pruning')):
            if timer_name == project + suffix:
                return name + ' ' + word
    return timer_name


def managed_timers():
    """Timers this setup installed (their files carry the setup's marker)."""
    timers = []
    for path in sorted(SYSTEMD.glob('opencj*.timer')):
        try:
            if path.read_text().startswith(maintenance.UNIT_MARKER):
                timers.append(path.stem)
        except OSError:
            continue
    return timers


def receipt_age_seconds(path, now):
    return now - path.stat().st_mtime if path.exists() else None


def live_server(container):
    """(map, players) from the local console; '?' when the console does not answer."""
    try:
        live = source_export.parse_console_status(source_export.console_output(container, 'status'))
        return live['map'], str(len(live['players']))
    except (RuntimeError, OSError, ValueError):
        return '?', '?'


def show_servers(host, plan, report):
    print(f"{'server':13} {'release':12} {'port':6} {'access':8} {'state':18} {'map':22} {'players':8} crashes")
    installations = []
    for name in plan.get('completed', []):
        instance = host / name
        settings = install.load_installation(instance, allow_other_release=True)
        installations.append((name, instance, settings))
        container = install.compose(instance, settings, 'ps', '--all', '--quiet', 'server')
        if not container:
            report.check(False, name + ': the game server container is missing')
            print(f"{name:13} {settings['release']:12} {settings['port']:<6} {'-':8} {'missing':18}")
            continue
        fields = install.run(['docker', 'inspect', '--format', '{{.State.Status}} '
                              '{{if .State.Health}}{{.State.Health.Status}}{{end}} {{.RestartCount}}',
                              container]).split()
        state, restarts = ' '.join(fields[:-1]), fields[-1]
        access = 'public' if settings['public'] else 'private'
        if is_switched_off(settings, fields[0]):
            print(f"{name:13} {settings['release']:12} {settings['port']:<6} {access:8} {'off (on demand)':18}")
            continue
        map_name, players = live_server(container)
        print(f"{name:13} {settings['release']:12} {settings['port']:<6} {access:8} {state:18} {map_name:22} "
              f"{players:8} {restarts}")
    return installations


def is_switched_off(settings, container_state):
    """An on-demand server stopped with `opencj stop`; Docker restarts crashed ones (state restarting)."""
    return bool(settings.get('on_demand')) and container_state in ('exited', 'created')


def show_services(installations, report):
    print('\nServices')
    for name, instance, settings in installations:
        if install.switched_off(instance, settings):
            print(f'  {name:13} off (on demand) - start with: sudo opencj start {name}')
            continue
        arguments = ['docker', 'compose', '-p', settings['project'], '-f', str(instance / 'compose.json')]
        text, problems = service_summary(expected_services(instance / 'compose.json'), compose_rows(arguments))
        for problem in problems:
            report.check(False, name + ': ' + problem)
        print(f'  {name:13} {text}')


def show_website(installations, report, now):
    for name, instance, settings in installations:
        website = settings.get('website')
        if not website:
            continue
        print('\nWebsite (' + name + ')')
        compose_file = instance / 'website/compose.json'
        text, problems = service_summary(expected_services(compose_file),
                                         compose_rows(managed_website.command(instance, settings)))
        for problem in problems:
            report.check(False, 'website: ' + problem)
        print('  ' + text)
        for domain in [website['domain'], *website.get('aliases', [])] if website.get('domain') else []:
            text, problem = check_certificate(domain, now)
            if problem:
                report.check(False, 'https://' + domain + ': ' + problem + ' (sudo opencj dns shows the records)')
            print(f'  https://{domain:30} {text}')


def show_backups(installations, report, now):
    print('\nBackups')
    for name, instance, settings in installations:
        policy = maintenance.backup_policy(settings)
        if not policy['enabled']:
            continue
        if install.switched_off(instance, settings):
            # Its data cannot change while it is off, so an old backup is still complete.
            print(f'  {name:13} paused while off (on demand)')
            continue
        details = []
        for label, path, needed in (('backup', instance / 'last-backup.json', True),
                                    ('off-site', instance / 'last-offsite.json',
                                     policy.get('offsite', {}).get('enabled', False))):
            if not needed:
                continue
            age = receipt_age_seconds(path, now)
            details.append(label + ' ' + ('not yet' if age is None else age_text(age)))
            if age is not None and age > RECEIPT_MAX_AGE_SECONDS:
                report.check(False, name + ': the last ' + label + ' is ' + age_text(age))
        prune = instance / 'last-prune.json'
        if prune.exists():
            details.append('pruned ' + str(read_json(prune).get('runs_deleted', '?')) + ' runs '
                           + age_text(now - prune.stat().st_mtime))
        print(f'  {name:13} ' + ', '.join(details))


def show_jobs(installations, report, now):
    print('\nScheduled jobs')
    projects = {settings['project']: name for name, instance, settings in installations}
    for timer in managed_timers():
        label = job_label(timer, projects)
        service = {'Result': unit_property(timer + '.service', 'Service', 'Result') or 'success'}
        text, problem = job_summary(label, timer_properties(timer), service, now)
        if problem:
            report.check(False, label + ': ' + problem + ' (journalctl -u ' + timer + ' -n 50)')
        print(f'  {label:28} {text}')


def show_dns(plan, report):
    names = dns_guide.wanted_names(plan)
    if not names:
        return
    print('\nDNS')
    addresses = dns_guide.public_addresses(plan)
    for name, purpose in names:
        issues = dns_guide.problems(name, addresses)
        if issues:
            report.check(False, name + ': ' + '; '.join(issues) + ' (sudo opencj dns)')
        print(f'  {name:32} ' + ('OK' if not issues else '; '.join(issues)) + f'  ({purpose})')


def show_host(host, plan, report):
    print('\nHost')
    usage = shutil.disk_usage(host)
    free_gib = usage.free / maintenance.GIB
    state = report.check(free_gib >= maintenance.DISK_ALERT_FREE_GIB, f'only {free_gib:.1f} GiB disk space is free')
    print(f'  Disk           {free_gib:.0f} GiB free of {usage.total / maintenance.GIB:.0f} GiB  {state}')
    firewall = quiet(['ufw', 'status']).splitlines()
    firewall_state = firewall[0].replace('Status: ', '') if firewall else 'not installed'
    if plan.get('firewall', {}).get('enabled'):
        report.check(firewall_state == 'active', 'the firewall is ' + firewall_state)
    print('  Firewall       ' + firewall_state)
    if plan.get('ssh_hardening', {}).get('fail2ban'):
        banned = re.search(r'Currently banned:\s+(\d+)', quiet(['fail2ban-client', 'status', 'sshd']))
        report.check(bool(banned), 'fail2ban is not running')
        print('  fail2ban       ' + (banned.group(1) + ' addresses banned now' if banned else 'NOT running'))
    updates = plan.get('security_updates', {})
    if updates.get('enabled'):
        active = quiet(['systemctl', 'is-active', 'apt-daily-upgrade.timer']).strip() == 'active'
        report.check(active, 'automatic security updates are not active')
        line = 'security updates ' + ('active' if active else 'NOT active')
        if REBOOT_REQUIRED.exists():
            if updates.get('reboot'):
                line += '; reboot pending (automatic at ' + updates.get('reboot_time', '05:30') + ')'
            else:
                report.check(False, 'an update needs a reboot: sudo reboot at a quiet moment')
                line += '; REBOOT NEEDED'
        print('  Updates        ' + line)
    webhook = plan.get('alerts', {}).get('discord_webhook')
    report.check(bool(webhook), 'alerts go only to the system journal: set a channel with sudo opencj alerts')
    print('  Alerts         ' + ('Discord webhook' if webhook else 'journal only'))


def show_status(host):
    """Print everything, then the list of what needs attention (or that all is well)."""
    plan = maintenance.host_plan(host)
    report = Report()
    now = time.time()
    installations = show_servers(host, plan, report)
    show_services(installations, report)
    show_website(installations, report, now)
    show_backups(installations, report, now)
    show_jobs(installations, report, now)
    show_dns(plan, report)
    show_host(host, plan, report)
    print('\nChecked ' + datetime.now(timezone.utc).astimezone().strftime('%Y-%m-%d %H:%M %Z') + '.')
    if report.attention:
        print('Needs attention:')
        for line in report.attention:
            print('  - ' + line)
    else:
        print('Everything OK.')
    return report
