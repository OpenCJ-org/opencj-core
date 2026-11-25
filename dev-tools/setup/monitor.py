"""Watch OpenCJ machines from outside: alert when a game server or the website stops answering.

This runs on another machine, normally the external backup server: the watchdog on the
game host cannot report its own machine, network or provider going down.
"""

import argparse
import getpass
import json
import os
from pathlib import Path
import re
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request

from maintenance import install_alert_unit, install_job, remove_job, run, send_webhook, validate_webhook
from operations import read_json, save_json

ROOT = Path(__file__).resolve().parents[2]
HOST = Path('/srv/opencj')
CONFIG = HOST / 'remote-monitor.json'
STATE = HOST / 'remote-monitor-state.json'
JOB = 'opencj-remote-monitor'
CHECK_SCHEDULE = '*:0/2'
# Three failed checks two minutes apart: a game server restarting after an update or
# a crash (well under a minute) never alerts, a real outage alerts within ~6 minutes.
FAILURES_BEFORE_ALERT = 3
STILL_DOWN_REPEAT_SECONDS = 6 * 3600
GAME_QUERY_ATTEMPTS = 3
GAME_QUERY_TIMEOUT_SECONDS = 3
WEBSITE_TIMEOUT_SECONDS = 15
# CoD4 servers answer this query whether or not they are password protected.
GAME_QUERY = b'\xff\xff\xff\xffgetinfo opencj-monitor\n'
GAME_REPLY_PREFIX = b'\xff\xff\xff\xffinfoResponse'
NAME_PATTERN = r'[a-z][a-z0-9-]{0,30}'
HOSTNAME_PATTERN = r'[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?'


def parse_target(text):
    """game:HOST:PORT or web:https://NAME/ -> a checked target."""
    kind, separator, rest = text.partition(':')
    if kind == 'game' and separator:
        host, separator, port = rest.rpartition(':')
        if not separator or not re.fullmatch(HOSTNAME_PATTERN, host) or not port.isdigit() \
                or not 1 <= int(port) <= 65535:
            raise ValueError('use game:HOST:PORT, for example game:eu.opencj.org:28960')
        return {'kind': 'game', 'host': host, 'port': int(port)}
    if kind == 'web' and re.fullmatch(r'https://' + HOSTNAME_PATTERN + r'(:[0-9]{1,5})?/?', rest):
        return {'kind': 'web', 'url': rest}
    raise ValueError('use game:HOST:PORT or web:https://NAME/')


def describe(target):
    if target['kind'] == 'game':
        return 'game server ' + target['host'] + ':' + str(target['port'])
    return 'website ' + target['url']


def probe_game(target):
    """None when the server answered a game query, otherwise what went wrong."""
    try:
        addresses = socket.getaddrinfo(target['host'], target['port'], type=socket.SOCK_DGRAM)
    except socket.gaierror as error:
        return 'name does not resolve (' + str(error) + ')'
    family, kind, protocol, _, address = addresses[0]
    with socket.socket(family, kind, protocol) as connection:
        connection.settimeout(GAME_QUERY_TIMEOUT_SECONDS)
        for _ in range(GAME_QUERY_ATTEMPTS):
            try:
                connection.sendto(GAME_QUERY, address)
                if connection.recv(4096).startswith(GAME_REPLY_PREFIX):
                    return None
            except OSError:
                continue
    return 'no answer to ' + str(GAME_QUERY_ATTEMPTS) + ' game queries'


def probe_website(target):
    """None when the website answered over HTTPS with a valid certificate."""
    request = urllib.request.Request(target['url'], headers={'User-Agent': 'OpenCJ-Monitor'})
    try:
        with urllib.request.urlopen(request, timeout=WEBSITE_TIMEOUT_SECONDS) as response:
            response.read(1024)
        return None
    except urllib.error.HTTPError as error:
        # A 4xx page still proves the machine and web server are up.
        return None if error.code < 500 else 'HTTP ' + str(error.code)
    except (urllib.error.URLError, ssl.SSLError, OSError) as error:
        reason = getattr(error, 'reason', error)
        return str(reason)[:200]


PROBES = {'game': probe_game, 'web': probe_website}


def run_checks(config, state, now, probe=None):
    """Check every target once; return the alert lines to post (possibly none).

    state is updated in place: per target the consecutive failures, when it went
    down and when it was last reported.
    """
    probe = probe or (lambda target: PROBES[target['kind']](target))
    lines = []
    for machine, targets in sorted(config['machines'].items()):
        for target in targets:
            key = machine + ' ' + describe(target)
            entry = state.setdefault(key, {'failures': 0})
            error = probe(target)
            if error is None:
                if entry['failures'] >= FAILURES_BEFORE_ALERT:
                    minutes = round((now - entry['down_since']) / 60)
                    lines.append(f'RECOVERED {machine}: {describe(target)} answers again'
                                 f' (down about {minutes} min).')
                state[key] = {'failures': 0}
                continue
            entry['failures'] += 1
            if entry['failures'] == 1:
                entry['down_since'] = now
            if entry['failures'] == FAILURES_BEFORE_ALERT or (
                    entry['failures'] > FAILURES_BEFORE_ALERT
                    and now - entry.get('reported', 0) >= STILL_DOWN_REPEAT_SECONDS):
                minutes = round((now - entry['down_since']) / 60)
                lines.append(f'DOWN {machine}: {describe(target)} - {error} (failing for about {minutes} min).')
                entry['reported'] = now
    # Forget targets that are no longer configured.
    configured = {machine + ' ' + describe(target)
                  for machine, targets in config['machines'].items() for target in targets}
    for key in list(state):
        if key not in configured:
            del state[key]
    return lines


def check_all():
    config = read_json(CONFIG)
    state = read_json(STATE) if STATE.exists() else {}
    lines = run_checks(config, state, time.time())
    save_json(STATE, state)
    if lines:
        # Machines being down are reported from here, so the host name says who is watching.
        send_webhook(config['webhook'], 'Outside check from ' + socket.gethostname() + ':\n' + '\n'.join(lines))


def ask_webhook(current):
    print('Alerts go to a Discord webhook; use the same private alert channel as the game host'
          ' (its URL is in /srv/opencj/host-setup.json there, or create a new webhook).', flush=True)
    while True:
        url = getpass.getpass('Discord webhook URL (hidden' + (', Enter keeps the current one' if current else '')
                              + '): ').strip()
        if not url and current:
            return current
        try:
            if url:
                return validate_webhook(url)
        except ValueError as error:
            print(error, flush=True)


def setup_monitor(name, targets, *, remove=False):
    """Add, replace or remove one watched machine, and keep the check job in step."""
    if os.geteuid() != 0:
        raise RuntimeError('Run with sudo: this installs a scheduled check')
    if not re.fullmatch(NAME_PATTERN, name):
        raise ValueError('Use a short name such as main-eu')
    HOST.mkdir(mode=0o700, exist_ok=True)
    config = read_json(CONFIG) if CONFIG.exists() else {'webhook': '', 'machines': {}}
    if remove:
        config['machines'].pop(name, None)
    else:
        if not targets:
            raise ValueError('Give at least one --target')
        config['machines'][name] = targets
        config['webhook'] = ask_webhook(config['webhook'])
    if not config['machines']:
        remove_job(JOB)
        CONFIG.unlink(missing_ok=True)
        STATE.unlink(missing_ok=True)
        run(['systemctl', 'daemon-reload'])
        print('No machines are watched any more; the outside check is removed.')
        return
    save_json(CONFIG, config)
    install_alert_unit(HOST)
    install_job(JOB, 'OpenCJ outside check of game servers and websites', CHECK_SCHEDULE,
                [ROOT / 'dev-tools/setup/monitor.py', '--check'], timeout_minutes=5, needs_docker=False)
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable', '--now', JOB + '.timer'])
    if remove:
        print('Stopped watching ' + name + '.')
        return
    for target in targets:
        error = PROBES[target['kind']](target)
        print(f"  {describe(target)}: {'answers' if error is None else 'NOT answering: ' + error}", flush=True)
    send_webhook(config['webhook'], 'Test from the outside check on ' + socket.gethostname() + ': ' + name
                 + ' is watched every 2 minutes; you are told here when it stops answering.')
    print('Watching ' + name + ' every 2 minutes. A test message was sent to the alert channel.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs='?', choices=['monitor'])
    parser.add_argument('--name', help='Name of the watched machine, for example main-eu')
    parser.add_argument('--target', action='append', default=[], type=parse_target,
                        help='game:HOST:PORT or web:https://NAME/ (repeat for each)')
    parser.add_argument('--remove', action='store_true', help='Stop watching this machine')
    parser.add_argument('--check', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    os.umask(0o077)
    if args.check:
        check_all()
        return
    if not args.name:
        parser.error('--name is required')
    setup_monitor(args.name, args.target, remove=args.remove)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError) as error:
        print('Error: ' + str(error), file=sys.stderr)
        sys.exit(1)
