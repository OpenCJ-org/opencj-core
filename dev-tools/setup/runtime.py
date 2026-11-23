#!/usr/bin/env python3
"""Start an installed release, keeping scripts immutable and player files persistent."""

import json
import os
from pathlib import Path
import socket
import sys

RUNTIME = Path('/runtime')
MOD = RUNTIME / 'mods/opencj'


def query_status():
    """Require an actual game-protocol reply, not just a running container process."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
        connection.settimeout(3)
        connection.sendto(b'\xff\xff\xff\xffgetstatus\n', ('127.0.0.1', 28960))
        reply = connection.recv(16384)
    return reply.startswith(b'\xff\xff\xff\xffstatusResponse')


def link_release_file(target, source):
    """Refuse to replace an operator's file with a generated release link."""
    if target.is_symlink():
        if os.readlink(target) != str(source):
            raise RuntimeError(f'Unexpected release link: {target.name}')
    elif target.exists():
        raise RuntimeError(f'Existing runtime file preserved: {target.name}')
    else:
        target.symlink_to(source)


def start_server():
    """Attach release assets and execute the engine without granting source write access."""
    settings = json.loads(Path('/run/opencj/runtime.json').read_text())
    MOD.mkdir(parents=True, exist_ok=True)
    (RUNTIME / 'plugins').mkdir(exist_ok=True)
    for name in ('opencj', 'maps'):
        link_release_file(MOD / name, Path('/opt/opencj/scripts') / name)
    for source in [Path('/mod-assets/mod.ff'), *Path('/mod-assets').glob('*.iwd')]:
        if not source.is_file():
            raise RuntimeError('Compiled mod assets are missing')
        link_release_file(MOD / source.name, source)
    link_release_file(MOD / 'server.cfg', Path('/run/opencj/server.cfg'))
    link_release_file(RUNTIME / 'steamclient.so', Path('/game/steamclient.so'))
    command = [
        '/opt/opencj/server', '+set', 'fs_basepath', '/game',
        '+set', 'fs_homepath', str(RUNTIME), '+set', 'fs_game', 'mods/opencj',
        '+set', 'dedicated', '2' if settings['public'] else '1',
        '+set', 'net_ip', '0.0.0.0', '+set', 'net_port', '28960',
        '+set', 'sv_maxclients', str(settings['slots']), '+set', 'com_hunkMegs', '1024',
        '+set', 'sv_authorizemode', '1', '+set', 'developer', '0',
        '+set', 'g_gametype', 'cj', '+exec', 'server.cfg', '+map', settings['map'],
    ]
    os.execv(command[0], command)


if __name__ == '__main__':
    if sys.argv[1:] == ['healthcheck']:
        try:
            sys.exit(0 if query_status() else 1)
        except OSError:
            sys.exit(1)
    start_server()
