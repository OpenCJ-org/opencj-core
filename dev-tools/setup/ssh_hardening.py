"""Harden the administrator's SSH access without any risk of locking them out.

Password logins are always switched off. If the administrator has no SSH key yet,
setup explains how to add one and waits until a login with that key has been seen,
so switching passwords off can never lock them out. fail2ban bans addresses that
keep failing. A port change is optional and done in two phases: SSH first listens on
both ports, and the old port closes only after a real login on the new port.
"""

from datetime import datetime
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys

from configuration import ask_port, ask_yes_no, prompt
from operations import run, write_private
import sshd

# How far back a key login in the journal counts as proof that the key works.
KEY_LOGIN_LOOKBACK = '-30d'

MARKER = '# Managed by OpenCJ setup\n'
SSHD_DROP_IN = Path('/etc/ssh/sshd_config.d/00-opencj-hardening.conf')
SSHD_PORT_DROP_IN = Path('/etc/ssh/sshd_config.d/01-opencj-port.conf')
SOCKET_DROP_IN = Path('/etc/systemd/system/ssh.socket.d/opencj-port.conf')
FAIL2BAN_JAIL = Path('/etc/fail2ban/jail.d/opencj-sshd.conf')
# Ports below 1024 are often used by other services; above 49151 are ephemeral client ports.
MIN_SSH_PORT = 1024
MAX_SSH_PORT = 49151


def administrator():
    """The account that ran sudo (root when setup runs as root); it must keep SSH access."""
    return pwd.getpwnam(os.environ.get('SUDO_USER') or 'root')


def has_authorized_key(account):
    keys = Path(account.pw_dir) / '.ssh/authorized_keys'
    if not keys.is_file():
        return False
    return any(re.match(r'\s*(ssh-|ecdsa-|sk-)', line) for line in keys.read_text(errors='replace').splitlines())


def current_ssh_ports():
    from firewall import ssh_ports
    return ssh_ports()


def key_login_seen(account, since):
    """True when the journal shows a login with an SSH key for this account since `since`."""
    result = subprocess.run(['journalctl', '--since', since, '--no-pager', '-o', 'cat',
                             '-t', 'sshd', '-t', 'sshd-session'],
                            capture_output=True, text=True, timeout=60)
    marker = 'Accepted publickey for ' + account.pw_name + ' '
    return any(line.startswith(marker) for line in result.stdout.splitlines())


def key_instructions(account):
    port = current_ssh_ports()[0]
    from dns_guide import public_addresses
    addresses = public_addresses()['A']
    host = addresses[0] if addresses else '<this server\'s address>'
    target = account.pw_name + '@' + host
    keys = Path(account.pw_dir) / '.ssh/authorized_keys'
    return ('\nSetup switches SSH password logins off: they are the main target of attacks. First add your'
            ' SSH key for ' + account.pw_name + ' (it goes into ' + str(keys) + '):\n'
            '  1. On your own computer, create a key if you have none:\n'
            '       ssh-keygen -t ed25519\n'
            '  2. Copy it to this server, on your own computer:\n'
            '       Linux or macOS:  ssh-copy-id -p ' + str(port) + ' ' + target + '\n'
            '       Windows PowerShell:\n'
            '         type $env:USERPROFILE\\.ssh\\id_ed25519.pub | ssh -p ' + str(port) + ' ' + target
            + ' "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600'
            ' ~/.ssh/authorized_keys"\n'
            '  3. Keep THIS session open. In a NEW terminal, log in again:\n'
            '       ssh -p ' + str(port) + ' ' + target + '\n'
            '     It must log you in without asking for this server\'s password.')


def wait_for_key_login(account):
    """Return only once a login with an SSH key for this account has been seen.

    A key that is merely present could still be wrong (other key, bad file
    permissions); only a real key login proves passwords can go.
    """
    if has_authorized_key(account) and key_login_seen(account, KEY_LOGIN_LOOKBACK):
        print('A login with your SSH key for ' + account.pw_name + ' was seen; password logins will be switched'
              ' off.', flush=True)
        return
    if not sys.stdin.isatty():
        raise RuntimeError('No SSH key login for ' + account.pw_name + ' has been seen, so passwords cannot be'
                           ' switched off safely.' + key_instructions(account))
    started = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    print(key_instructions(account), flush=True)
    while True:
        prompt('Press Enter here once that key login works')
        if not has_authorized_key(account):
            print('No key is in ' + str(Path(account.pw_dir) / '.ssh/authorized_keys') + ' yet. Repeat step 2.',
                  flush=True)
            continue
        if key_login_seen(account, started):
            print('Key login seen. Password logins will be switched off.', flush=True)
            return
        print('The key is there, but no login with it was seen since ' + started + '. Do step 3; if it still asks'
              ' for a password, check that ~/.ssh is 700 and authorized_keys is 600, owned by '
              + account.pw_name + '.', flush=True)


def collect_ssh_hardening():
    print('\nSSH access: key-only login and fail2ban stop password guessing; a different port mainly'
          ' reduces log noise from scanners.', flush=True)
    wait_for_key_login(administrator())
    result = {'key_only': True, 'fail2ban': ask_yes_no('Ban addresses that keep failing to log in (fail2ban)?',
                                                        True)}
    ports = current_ssh_ports()
    if ask_yes_no('Move SSH from port ' + '/'.join(map(str, ports)) + ' to another port?', False):
        result['new_port'] = ask_port('New SSH port (' + str(MIN_SSH_PORT) + '-' + str(MAX_SSH_PORT) + ')', 2222)
        if not MIN_SSH_PORT <= result['new_port'] <= MAX_SSH_PORT:
            raise ValueError('Use an SSH port from ' + str(MIN_SSH_PORT) + ' to ' + str(MAX_SSH_PORT))
    return result


def validate_ssh_hardening(hardening):
    """Check an unattended plan's SSH choices before anything changes."""
    if not isinstance(hardening, dict):
        raise ValueError('ssh_hardening must be an object')
    if not hardening:
        return {}
    result = dict(hardening)
    result.setdefault('key_only', True)
    result.setdefault('fail2ban', False)
    for field in ('key_only', 'fail2ban'):
        if type(result[field]) is not bool:
            raise ValueError('ssh_hardening.' + field + ' must be a Boolean')
    if not result['key_only']:
        raise ValueError('ssh_hardening.key_only must be true: password logins are not left enabled')
    if 'new_port' in result:
        port = result['new_port']
        if type(port) is not int or not MIN_SSH_PORT <= port <= MAX_SSH_PORT:
            raise ValueError('ssh_hardening.new_port must be ' + str(MIN_SSH_PORT) + '-' + str(MAX_SSH_PORT))
    return result


def managed(path, contents):
    if path.exists() and not path.read_text().startswith(MARKER):
        raise RuntimeError('Existing configuration preserved: ' + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    write_private(path, MARKER + contents)
    path.chmod(0o644)


def socket_activated():
    """Ubuntu 24.04 starts sshd through ssh.socket; its ports are set there, not in sshd_config."""
    result = subprocess.run(['systemctl', 'is-enabled', 'ssh.socket'], capture_output=True, text=True, timeout=30)
    return result.stdout.strip() == 'enabled'


def socket_listen_lines(ports):
    """IPv4 and IPv6 sockets for every port, like Ubuntu's own ssh.socket.

    Ubuntu's unit sets BindIPv6Only=ipv6-only, so a bare `ListenStream=22` would
    listen on IPv6 only and silently lock out every IPv4 client.
    """
    lines = '[Socket]\nListenStream=\nBindIPv6Only=ipv6-only\n'
    for port in ports:
        lines += 'ListenStream=0.0.0.0:' + str(port) + '\nListenStream=[::]:' + str(port) + '\n'
    return lines


def apply_listen_configuration():
    if socket_activated():
        run(['systemctl', 'daemon-reload'])
        run(['systemctl', 'restart', 'ssh.socket'])
    else:
        sshd.reload()


def listen_on(ports):
    """Make SSH listen on exactly these ports, then prove it with real connections.

    Existing sessions are not interrupted. If SSH does not answer on every port over
    IPv4 and IPv6 afterwards, the previous configuration is restored at once.
    """
    drop_ins = [SSHD_PORT_DROP_IN, SOCKET_DROP_IN]
    previous = {path: (path.read_text() if path.exists() else None) for path in drop_ins}
    try:
        managed(SSHD_PORT_DROP_IN, ''.join('Port ' + str(port) + '\n' for port in ports))
        sshd.sshd('-t')
        if socket_activated():
            managed(SOCKET_DROP_IN, socket_listen_lines(ports))
        apply_listen_configuration()
        if current_ssh_ports() != sorted(ports):
            raise RuntimeError('Another SSH setting (for example a Port line in /etc/ssh/sshd_config) keeps'
                               ' other ports')
        for port in ports:
            if not sshd.answers_on(port):
                raise RuntimeError('SSH does not answer on port ' + str(port) + ' over IPv4 and IPv6')
    except Exception:
        for path, contents in previous.items():
            if contents is None:
                path.unlink(missing_ok=True)
            else:
                write_private(path, contents)
                path.chmod(0o644)
        apply_listen_configuration()
        raise


def listening_ssh_ports():
    output = run(['ss', '-Hltn'])
    return {int(match.group(1)) for match in re.finditer(r'[:\]](\d+)\s', output)}


def established_on(port):
    """True when some client is logged in through this port right now."""
    output = run(['ss', '-Htn', 'state', 'established', '( sport = :' + str(port) + ' )'])
    return bool(output.strip())


def apply_key_only(enabled):
    """Switch password logins off; refuses (setup stops, nothing changed) while the administrator has no key."""
    if not enabled:
        return
    account = administrator()
    if not account or not has_authorized_key(account):
        raise RuntimeError('No authorized SSH key found for the administrator. Add one (sudo opencj install'
                           ' explains how) and run setup again; nothing was changed.')
    # 00- sorts first: sshd uses the first value it reads for each option.
    managed(SSHD_DROP_IN, 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password\n')
    sshd.sshd('-t')
    sshd.reload()


def apply_fail2ban(enabled, ports):
    if not enabled:
        return
    run(['apt-get', 'install', '-y', 'fail2ban'], timeout=900)
    managed(FAIL2BAN_JAIL, '[sshd]\nenabled = true\nport = ' + ','.join(map(str, ports)) + '\n'
            'backend = systemd\nmaxretry = 5\nfindtime = 10m\nbantime = 1h\n')
    run(['systemctl', 'enable', 'fail2ban'])
    run(['systemctl', 'restart', 'fail2ban'])


def move_port(plan, new_port, open_firewall):
    """Two-phase move: listen on both ports, verify a real login on the new one, then close the old."""
    old_ports = [port for port in current_ssh_ports() if port != new_port]
    hardening = plan['ssh_hardening']
    if hardening.get('port_moved'):
        return
    # Open the firewall for the new port before SSH starts using it.
    hardening['ports'] = sorted({*old_ports, new_port})
    open_firewall(extra_ssh_ports=[new_port])
    listen_on(hardening['ports'])
    if new_port not in listening_ssh_ports():
        raise RuntimeError('SSH does not listen on port ' + str(new_port) + '; the old port stays open')
    from dns_guide import public_addresses
    addresses = public_addresses()['A']
    host = prompt('This server\'s address for your SSH client', addresses[0] if addresses else os.uname().nodename)
    account = administrator()
    user = account.pw_name if account else 'root'
    print('\nKeep this session open. In a NEW terminal, log in with:\n  ssh -p ' + str(new_port) + ' '
          + user + '@' + host + '\nand stay logged in there.', flush=True)
    prompt('Press Enter here once that new login works')
    if not established_on(new_port):
        print('No login on port ' + str(new_port) + ' was seen. SSH keeps listening on both ports '
              + '/'.join(map(str, hardening['ports'])) + '; rerun setup to try again.', flush=True)
        return
    listen_on([new_port])
    hardening['ports'] = [new_port]
    hardening['port_moved'] = True
    open_firewall(extra_ssh_ports=[])
    print('SSH now listens only on port ' + str(new_port) + '. Use: ssh -p ' + str(new_port) + ' '
          + user + '@' + host, flush=True)


def apply_ssh_hardening(plan, open_firewall):
    """Apply the chosen hardening; open_firewall re-applies firewall rules for the current SSH ports."""
    hardening = plan.get('ssh_hardening', {})
    if not hardening:
        return
    apply_key_only(hardening.get('key_only', False))
    if hardening.get('new_port'):
        move_port(plan, hardening['new_port'], open_firewall)
    apply_fail2ban(hardening.get('fail2ban', False), current_ssh_ports() + hardening.get('ports', []))
