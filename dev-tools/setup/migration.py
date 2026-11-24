"""Transfer complete private bundles and restore only an unaccepted owned database."""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

import shutil

from assets import sha256_file, shared_assets_root, validate_assets
from operations import inspect_container, read_json, run, save_json, TRANSFER_TIMEOUT_SECONDS
from operations import require_migration_space
from source import copy_file, database_inventory, export_source, resume_source, FORMAT_VERSION

ROOT = Path(__file__).resolve().parents[2]
MAX_BUNDLE_FILES = 200000


def ssh_arguments(settings):
    ssh = settings['ssh']
    return ['ssh', '-p', str(ssh['port']), '-i', ssh['key'],
            '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'UserKnownHostsFile=' + ssh['known_hosts'],
            '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30',
            '-o', 'ServerAliveCountMax=3']


def validate_bundle(bundle, *, published_kinds=()):
    """Verify exact file membership, traversal boundaries and every transferred byte.

    published_kinds lists asset kinds ('game', 'mod') already moved into the host's
    shared asset folder; they were verified before that move and are skipped here.
    """
    manifest = read_json(bundle / 'manifest.json')
    if manifest.get('format') != FORMAT_VERSION:
        raise ValueError('Unsupported migration bundle format')
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,62}4', manifest['database']):
        raise ValueError('Invalid migration database name')
    if not re.fullmatch(r'[a-z0-9_]+', manifest['map']):
        raise ValueError('Invalid migration map')
    if len(manifest['files']) > MAX_BUNDLE_FILES:
        raise ValueError('Migration file inventory is too large')
    asset_kinds = []
    if manifest.get('includes_assets', True):
        asset_kinds = [kind for kind in ('game', 'mod') if kind not in published_kinds]
    skipped_prefixes = tuple(kind + '/' for kind in ('game', 'mod') if kind not in asset_kinds)
    expected_files = {name: value for name, value in manifest['files'].items()
                      if not name.startswith(skipped_prefixes)}
    actual = set()
    for name in [*asset_kinds, 'runtime', 'source-config']:
        for path in (bundle / name).rglob('*'):
            if path.is_symlink():
                raise ValueError('Migration bundles cannot contain links')
            if path.is_file():
                actual.add(path.relative_to(bundle).as_posix())
    actual.add('database.sql')
    if actual != set(expected_files):
        raise ValueError('Migration files differ from the exported inventory')
    for name, expected in expected_files.items():
        path = bundle / name
        if Path(name).is_absolute() or '..' in Path(name).parts or not path.resolve().is_relative_to(bundle.resolve()):
            raise ValueError('Migration file escapes the bundle')
        if path.is_symlink() or not path.is_file():
            raise ValueError('Migration file is missing or is a link')
        if path.stat().st_size != expected['bytes'] or sha256_file(path) != expected['sha256']:
            raise ValueError('Migration checksum mismatch; existing installation preserved')
    for kind in asset_kinds:
        validate_assets(bundle / kind, kind)
    return manifest


def transfer_bundle(command, bundle, log):
    """Estimate only files still needing transfer, then leave service disk headroom."""
    preview = ['env', 'LC_ALL=C', command[0], '--dry-run', '--stats', '--out-format=', *command[1:]]
    statistics = run(preview, timeout=TRANSFER_TIMEOUT_SECONDS)
    match = re.search(r'Total transferred file size: ([0-9,]+) bytes', statistics)
    if not match:
        raise RuntimeError('Unable to estimate remaining migration transfer size')
    incoming_bytes = int(match.group(1).replace(',', ''))
    require_migration_space(bundle, incoming_bytes)
    run(command, timeout=TRANSFER_TIMEOUT_SECONDS, log=log)


def prepare_bundle(instance, settings):
    """Export and transfer automatically; rsync resumes partial transfers within this instance."""
    migration = settings['migration']
    directory = instance / 'migration'
    directory.mkdir(mode=0o700, exist_ok=True)
    bundle = directory / 'bundle'
    bundle.mkdir(mode=0o700, exist_ok=True)
    if not migration.get('verified'):
        if migration['transport'] == 'bundle':
            source = str(Path(migration['bundle']).resolve()) + '/'
            command = ['rsync', '-rt', '--protect-args', '--no-links', '--partial', '--partial-dir=.partial', source, str(bundle) + '/']
        else:
            source_bundle = migration['source_bundle']
            arguments = [
                'python3', '-B', migration['source_root'] + '/dev-tools/setup/migration.py', 'export',
                '--source-instance', migration['source_instance'], '--bundle', source_bundle,
                '--intent', migration['intent'], '--allow-player', migration.get('allowed_player', ''),
            ]
            if migration.get('shared_assets'):
                # Same host: the copy uses the shared asset folder, so only data moves.
                arguments.append('--without-assets')
                migration['assets_transferred'] = True
            if migration.get('sudo'):
                arguments = ['sudo', '-n', *arguments]
            if migration['transport'] == 'local':
                export_command = arguments
                prepare_command = [*arguments, '--prepare-only']
                command = ['rsync', '-rt', '--protect-args', '--no-links', '--partial', '--partial-dir=.partial',
                           source_bundle + '/', str(bundle) + '/']
            else:
                ssh = migration['ssh']
                endpoint = ssh['user'] + '@' + ssh['host']
                export_command = [*ssh_arguments(migration), endpoint, shlex.join(arguments)]
                prepare_command = [*ssh_arguments(migration), endpoint, shlex.join([*arguments, '--prepare-only'])]
                command = ['rsync', '-rt', '--protect-args', '--no-links', '--partial', '--partial-dir=.partial',
                           '-e', shlex.join(ssh_arguments(migration)),
                           endpoint + ':' + source_bundle + '/', str(bundle) + '/']
                if migration.get('sudo'):
                    command.insert(1, '--rsync-path=sudo -n rsync')
            if not migration.get('assets_transferred'):
                run(prepare_command, timeout=TRANSFER_TIMEOUT_SECONDS, log=instance / 'migration-export.log')
                print('Copying game assets and maps before source maintenance...', flush=True)
                transfer_bundle(command, bundle, instance / 'migration-transfer.log')
                migration['assets_transferred'] = True
                save_json(instance / 'installation.json', settings)
            run(export_command, timeout=TRANSFER_TIMEOUT_SECONDS, log=instance / 'migration-export.log')
            print('Transferring the consistent database and runtime snapshot...', flush=True)
        transfer_bundle(command, bundle, instance / 'migration-transfer.log')
        manifest = validate_bundle(bundle)
        migration['manifest_sha256'] = sha256_file(bundle / 'manifest.json')
        migration['verified'] = True
        migration['database_restored'] = False
        settings['database']['name'] = manifest['database']
        settings['map'] = manifest['map']
    else:
        if sha256_file(bundle / 'manifest.json') != migration['manifest_sha256']:
            raise RuntimeError('Migration manifest changed; preserved without using it')
        manifest = validate_bundle(bundle, published_kinds=migration.get('published_kinds', []))
    publish_shared_assets(instance, settings, bundle, manifest)
    return manifest


def publish_shared_assets(instance, settings, bundle, manifest):
    """Move verified game files and maps into the host's shared asset folder.

    Every installation on this host reads the same read-only copy, so maps are
    stored once. Moving within one filesystem is instant; each kind is recorded
    when done, so an interrupted run resumes without re-validating moved files.
    """
    root = shared_assets_root(instance)
    root.mkdir(mode=0o755, exist_ok=True)
    root.chmod(0o755)
    migration = settings['migration']
    published = migration.setdefault('published_kinds', [])
    for kind in ('game', 'mod'):
        target = root / kind
        if manifest.get('includes_assets', True) and kind not in published:
            source = bundle / kind
            # Containers bind these folders read-only; only public game data becomes readable.
            for path in [source, *source.rglob('*')]:
                path.chmod(0o755 if path.is_dir() else 0o644)
            if target.exists():
                # Another migration already filled the shared folder: add new or
                # changed files from this source without deleting anything.
                run(['rsync', '-rt', '--no-links', str(source) + '/', str(target) + '/'],
                    timeout=TRANSFER_TIMEOUT_SECONDS)
                shutil.rmtree(source)
            else:
                os.replace(source, target)
            published.append(kind)
            save_json(instance / 'installation.json', settings)
        validate_assets(target, kind)
        settings[kind + '_dir'] = str(target)


def restore_runtime(instance, settings, *, bundle=None):
    """Resume copied player/editor files without replacing an operator's differing file."""
    if bundle is None:
        bundle = instance / 'migration/bundle'
    manifest = read_json(bundle / 'manifest.json')
    owner = (settings['uid'], settings['gid'])
    for name, expected in manifest['files'].items():
        if not name.startswith('runtime/'):
            continue
        relative = Path(name).relative_to('runtime')
        if relative.parts[:3] in (('mods', 'opencj', 'opencj'), ('mods', 'opencj', 'maps')):
            raise ValueError('Migration runtime contains managed scripts')
        target = instance / 'runtime' / relative
        if target.exists():
            if sha256_file(target) != expected['sha256']:
                raise RuntimeError('Runtime file changed since migration; existing file preserved')
            continue
        # Publish only complete files; a failed copy must not become a conflicting draft on retry.
        copy_file(bundle / name, target)
    if os.getuid() == 0:
        for path in [instance / 'runtime', *(instance / 'runtime').rglob('*')]:
            if not path.is_symlink():
                os.chown(path, *owner)


def reset_incomplete_restore(instance, settings):
    """Discard only this instance's unaccepted restore copy, never a ready database."""
    migration = settings['migration']
    if migration.get('restore_state') != 'importing':
        return
    if settings['state'] not in ('prepared', 'configured'):
        raise RuntimeError('Database already accepted; automatic restore replacement refused')
    project = settings['project']
    containers = run(['docker', 'ps', '-aq', '--filter', 'label=com.docker.compose.project=' + project]).splitlines()
    for container in containers:
        metadata = inspect_container(container)
        if metadata['Config']['Labels'].get('com.docker.compose.service') != 'db':
            raise RuntimeError('Gameplay resources exist; incomplete database cannot be replaced automatically')
        run(['docker', 'rm', '-f', container])
    volumes = run(['docker', 'volume', 'ls', '--format', '{{.Name}}']).splitlines()
    if settings['volume'] in volumes:
        metadata = json.loads(run(['docker', 'volume', 'inspect', settings['volume']]))[0]
        if metadata.get('Labels', {}).get('org.opencj.instance') != project:
            raise RuntimeError('Restore volume ownership mismatch; preserved')
        run(['docker', 'volume', 'rm', settings['volume']])
    migration['restore_state'] = 'pending'
    save_json(instance / 'installation.json', settings)


def restore_database(instance, settings, db, container):
    """Restore into an empty owned candidate, then prove that every table matches."""
    migration = settings['migration']
    if migration.get('database_restored'):
        return
    bundle = instance / 'migration/bundle'
    manifest = read_json(bundle / 'manifest.json')
    if db.query('SELECT VERSION();') != manifest['mysql_version']:
        raise RuntimeError('Restore requires the source MySQL version; change the candidate image deliberately')
    if db.query('SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE();') != '0':
        raise RuntimeError('Restore candidate is not empty; existing data preserved')
    migration['restore_state'] = 'importing'
    save_json(instance / 'installation.json', settings)
    command = ['docker', 'exec', '-i', container, 'sh', '-c',
               'MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-$(cat \"$MYSQL_ROOT_PASSWORD_FILE\")}" exec mysql -u root']
    with (bundle / 'database.sql').open('rb') as incoming:
        run(command, stdin=incoming, timeout=TRANSFER_TIMEOUT_SECONDS, log=instance / 'restore.log')
    if database_inventory(db) != manifest['tables']:
        raise RuntimeError('Restored database content differs from the source snapshot')
    migration['database_restored'] = True
    migration['restore_state'] = 'verified'
    save_json(instance / 'installation.json', settings)


def source_control(instance, settings, action):
    """Keep cutover retries tied to the source's fencing receipt."""
    migration = settings.get('migration', {})
    if migration.get('intent') != 'cutover' or migration.get('source_accepted'):
        return
    arguments = ['python3', '-B', migration['source_root'] + '/dev-tools/setup/migration.py',
                 action, '--bundle', migration['source_bundle']]
    if migration.get('sudo'):
        arguments = ['sudo', '-n', *arguments]
    if migration['transport'] == 'ssh':
        ssh = migration['ssh']
        arguments = [*ssh_arguments(migration), ssh['user'] + '@' + ssh['host'], shlex.join(arguments)]
    run(arguments, log=instance / 'migration-export.log')
    if action == 'accept-cutover':
        migration['source_accepted'] = True
        save_json(instance / 'installation.json', settings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='action', required=True)
    export = commands.add_parser('export')
    export.add_argument('--source-instance', type=Path, required=True)
    export.add_argument('--bundle', type=Path, required=True)
    export.add_argument('--intent', choices=('rehearsal', 'cutover'), default='rehearsal')
    export.add_argument('--allow-player', default='')
    export.add_argument('--prepare-only', action='store_true')
    export.add_argument('--without-assets', action='store_true')
    resume = commands.add_parser('resume-source')
    resume.add_argument('--bundle', type=Path, required=True)
    for action in ('check-fenced', 'accept-cutover'):
        control = commands.add_parser(action)
        control.add_argument('--bundle', type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    if args.action == 'export':
        export_source(args.source_instance, args.bundle, intent=args.intent,
                      allowed_player=args.allow_player, prepare_only=args.prepare_only,
                      without_assets=args.without_assets)
        print('Migration snapshot is complete.')
    else:
        bundle = args.bundle.resolve()
        journal = read_json(bundle / 'journal.json')
        from operations import operation_lock
        with operation_lock(Path(journal['source']['directory']) / '.setup.lock'):
            with operation_lock(bundle / '.export.lock'):
                if args.action == 'resume-source':
                    if journal.get('state') == 'accepted':
                        raise RuntimeError('Destination has accepted this cutover; preserve its newer writes before rollback')
                    resume_source(bundle, journal)
                    if journal['intent'] == 'cutover':
                        journal['state'] = 'cancelled'
                        save_json(bundle / 'journal.json', journal)
                    print('Source state and captured map restored.')
                else:
                    if journal['intent'] != 'cutover' or journal['state'] not in ('complete', 'accepted'):
                        raise RuntimeError('Source is not a completed cutover')
                    for service in ('server', 'db'):
                        if inspect_container(journal['source'][service])['State']['Running']:
                            raise RuntimeError('Source service was restarted; destination cutover refused')
                    if args.action == 'accept-cutover':
                        journal['state'] = 'accepted'
                        save_json(bundle / 'journal.json', journal)
                    print('Source cutover fencing verified.')



if __name__ == '__main__':
    main()
