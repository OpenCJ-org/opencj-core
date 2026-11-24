"""Safe interaction with the host's SSH server, including Ubuntu 24.04's socket-activated setup.

With socket activation (ssh.socket), sshd itself only starts when the first client
connects. Until then its privilege-separation folder /run/sshd does not exist, so
`sshd -t` / `sshd -T` fail, and ssh.service is inactive, so a plain reload fails.
"""

from pathlib import Path
import socket

from operations import run

SSHD = '/usr/sbin/sshd'
PRIVILEGE_SEPARATION_DIRECTORY = Path('/run/sshd')
BANNER_TIMEOUT_SECONDS = 10


def sshd(*arguments):
    """Run sshd in test mode (-t, -T, ...); creates the folder ssh.service would create."""
    PRIVILEGE_SEPARATION_DIRECTORY.mkdir(mode=0o755, exist_ok=True)
    return run([SSHD, *arguments])


def reload():
    """Apply sshd_config changes: a running sshd reloads, a not-yet-started one reads them when it starts."""
    run(['systemctl', 'try-reload-or-restart', 'ssh.service'])


def ipv6_loopback_available():
    try:
        return '00000000000000000000000000000001' in Path('/proc/net/if_inet6').read_text()
    except OSError:
        return False


def answers_on(port):
    """True when SSH really answers on this port, over IPv4 and (when the host has it) IPv6.

    Opens a connection and waits for the SSH banner, as a client would. A listening
    socket alone is not enough: it can be bound for one address family only.
    """
    addresses = [(socket.AF_INET, '127.0.0.1')]
    if ipv6_loopback_available():
        addresses.append((socket.AF_INET6, '::1'))
    for family, address in addresses:
        try:
            with socket.socket(family, socket.SOCK_STREAM) as connection:
                connection.settimeout(BANNER_TIMEOUT_SECONDS)
                connection.connect((address, port))
                banner = connection.recv(64)
        except OSError:
            return False
        if not banner.startswith(b'SSH-'):
            return False
    return True
