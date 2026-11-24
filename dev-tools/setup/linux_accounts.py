"""Dedicated locked Linux identities for each installed service, never Docker administrators."""

import os
import pwd

from operations import run


def ensure_accounts(settings):
    """Create owned system users once; refuse unrelated accounts or expanded group access."""
    if os.geteuid() != 0:
        raise RuntimeError('Run with sudo: setup provisions restricted Linux service accounts')
    roles = ['game']
    if settings['database'].get('transport') == 'ssh':
        roles.append('tunnel')
    if settings['database']['mode'] == 'new':
        roles.append('database')
    if settings.get('website'):
        roles.extend(['website', 'http'])
    if settings.get('discord', {}).get('enabled'):
        roles.append('discord')
    if settings.get('geoip', {}).get('enabled'):
        roles.append('geoip')
    identities = settings.setdefault('linux_accounts', {})
    suffix = settings['project'].rsplit('-', 1)[1]
    for role in roles:
        name = 'ocj_' + role + '_' + suffix
        marker = 'OpenCJ ' + settings['project'] + ' ' + role
        try:
            account = pwd.getpwnam(name)
        except KeyError:
            run(['useradd', '--system', '--user-group', '--no-create-home',
                 '--home-dir', '/nonexistent', '--shell', '/usr/sbin/nologin',
                 '--comment', marker, name])
            account = pwd.getpwnam(name)
        if account.pw_gecos != marker or account.pw_shell != '/usr/sbin/nologin' or account.pw_dir != '/nonexistent':
            raise RuntimeError('Linux account belongs to another owner or permits login; preserved')
        if account.pw_uid == 0 or os.getgrouplist(name, account.pw_gid) != [account.pw_gid]:
            raise RuntimeError('Service account has additional group privileges; installation refused')
        status = run(['passwd', '--status', name]).split()
        if len(status) < 2 or status[1] != 'L':
            raise RuntimeError('Service account is not password-locked')
        identity = {'name': name, 'uid': account.pw_uid, 'gid': account.pw_gid}
        if role in identities and identities[role] != identity:
            raise RuntimeError('Recorded service identity changed; existing files preserved')
        identities[role] = identity
    settings['uid'] = identities['game']['uid']
    settings['gid'] = identities['game']['gid']


def verify_accounts(settings):
    for role, identity in settings.get('linux_accounts', {}).items():
        account = pwd.getpwnam(identity['name'])
        marker = 'OpenCJ ' + settings['project'] + ' ' + role
        status = run(['passwd', '--status', account.pw_name]).split()
        if account.pw_gecos != marker or len(status) < 2 or status[1] != 'L':
            raise RuntimeError('Linux service ownership or password lock changed')
        if (account.pw_uid, account.pw_gid) != (identity['uid'], identity['gid']):
            raise RuntimeError('Linux service ownership changed')
        if (account.pw_shell != '/usr/sbin/nologin' or account.pw_dir != '/nonexistent'
                or os.getgrouplist(account.pw_name, account.pw_gid) != [account.pw_gid]):
            raise RuntimeError('Linux service permissions changed')


def remove_fixture_accounts(settings):
    """Tests may remove only identities carrying their exact recorded ownership marker."""
    if os.geteuid() != 0:
        raise RuntimeError('Fixture account cleanup requires root')
    for role, identity in settings.get('linux_accounts', {}).items():
        account = pwd.getpwnam(identity['name'])
        marker = 'OpenCJ ' + settings['project'] + ' ' + role
        if account.pw_gecos != marker or account.pw_uid != identity['uid']:
            raise RuntimeError('Fixture account ownership changed; preserved')
        run(['userdel', identity['name']])
