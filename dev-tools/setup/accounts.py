"""Provision separately revocable instance accounts without adopting unrelated users."""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'server-db/tools'))
import runtime_access

GAME_CONNECTION_LIMIT = 32


def provision_owned_account(db, account, password, owner, *, connection_limit):
    """Retry only an account carrying this installation's ownership marker."""
    if not re.fullmatch(r'[A-Za-z0-9_]{1,32}', account):
        raise ValueError('Invalid application account')
    literal = runtime_access.quote_literal
    principal = literal(account) + "@'%'"
    lock_name = 'opencj:account:' + account
    if db.query('SELECT GET_LOCK(' + literal(lock_name) + ', 0);') != '1':
        raise RuntimeError('Another operation is provisioning this account')
    try:
        attributes = db.query(
            'SELECT COALESCE(ATTRIBUTE, JSON_OBJECT()) FROM information_schema.USER_ATTRIBUTES '
            'WHERE USER=' + literal(account) + " AND HOST='%';")
        if attributes:
            if json.loads(attributes).get('opencj_instance') != owner:
                raise RuntimeError('Existing database account belongs to another owner; preserved')
        else:
            marker = json.dumps({'opencj_instance': owner})
            db.query('CREATE USER ' + principal + ' IDENTIFIED BY ' + literal(password)
                     + ' ATTRIBUTE ' + literal(marker) + ';')
        db.query('ALTER USER ' + principal + ' IDENTIFIED BY ' + literal(password)
                 + ' WITH MAX_USER_CONNECTIONS ' + str(connection_limit) + ';')
    finally:
        db.query('SELECT RELEASE_LOCK(' + literal(lock_name) + ');')
    return principal


def provision_game_account(db, settings):
    database = settings['database']
    provision_owned_account(db, database['user'], database['password'], settings['project'],
                            connection_limit=GAME_CONNECTION_LIMIT)
    runtime_access.apply_policy(db, database['name'], account=database['user'])
