"""Test GeoIP schema/import in an isolated schema; remove its temporary account."""

from compose_environment import database_container, database_network
from pathlib import Path
import argparse
import importlib.util
import os
import subprocess
import sys
import uuid

R = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(R / 'server-db/tools'))
from mysql_session import MySQL

spec = importlib.util.spec_from_file_location(
    'geoip_provision', R / 'server-db/tools/geoip/provision.py'
)
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    '--image', default='opencj-geoip-updater:latest', help='Locally built GeoIP updater image'
)
options = parser.parse_args()
if subprocess.run(['docker', 'image', 'inspect', options.image], capture_output=True).returncode:
    parser.error(
        'Build the updater image first: docker build -t ' + options.image + ' server-db/tools/geoip'
    )
container = database_container()
network = database_network()
tag = uuid.uuid4().hex[:8]
schema = 'opencj_geoip_test_' + tag
account = 'geoip_test_' + tag
w = R / 'dev-tools/local' / ('geoip-integration-' + tag)
w.mkdir(parents=True, mode=0o700)
secret = w / 'test-password'
updater = 'opencj-geoip-fixture-' + tag
created = False
try:
    with MySQL(container, 'openCJ_cod4') as admin:
        admin.query('CREATE DATABASE ' + schema + ';')
        created = True
    with MySQL(container, schema) as db:
        db.query(
            'CREATE TABLE longCountry(country CHAR(2) PRIMARY KEY,longCountry VARCHAR(128)); INSERT INTO longCountry VALUES("GB","United Kingdom");'
        )
        db.query((R / 'server-db/migrations/025-geoip-country.sql').read_text())
    provision.provision(container, schema, secret, account=account)
    with MySQL(container, schema) as admin:
        for name in ['getCountry', 'geoIPLookupCode']:
            admin.query(
                "GRANT EXECUTE ON FUNCTION " + schema + "." + name + " TO '" + account + "'@'%';"
            )
    command = [
        'docker',
        'run',
        '--rm',
        '--name',
        updater,
        '--network',
        network,
        '--user',
        str(os.getuid()) + ':' + str(os.getgid()),
        '--read-only',
        '--tmpfs',
        '/tmp:size=128m',
        '-e',
        'GEOIP_DB_HOST=db',
        '-e',
        'GEOIP_DB_NAME=' + schema,
        '-e',
        'GEOIP_DB_USER=' + account,
        '-e',
        'GEOIP_DB_PASSWORD_FILE=/run/secret',
        '-v',
        str(secret) + ':/run/secret:ro',
        '-v',
        str(R / 'server-db/tools/geoip') + ':/source:ro',
        '--entrypoint',
        'python',
        options.image,
        '/source/test_database.py',
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=90)
    if result.returncode:
        print(result.stdout)
        print(result.stderr[-3500:])
        raise RuntimeError('Isolated GeoIP database test failed')
    print(result.stdout)
    (w / 'database-test-result.json').write_text(result.stdout)
finally:
    try:
        subprocess.run(['docker', 'rm', '-f', updater], capture_output=True)
        if created:
            with MySQL(container, 'openCJ_cod4') as admin:
                admin.query(
                    "DROP DATABASE " + schema + "; DROP USER IF EXISTS '" + account + "'@'%';"
                )
    finally:
        secret.unlink(missing_ok=True)
