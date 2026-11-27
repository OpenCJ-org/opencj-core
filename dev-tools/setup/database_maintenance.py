"""Fence every managed writer during database replacement or schema maintenance."""

from contextlib import ExitStack
from pathlib import Path

import install
from configuration import ask_yes_no
from operations import operation_lock, read_json, save_json
import service_control
import source


class DatabaseMaintenance:
    """Keep a durable fence after failures; only a verified completion restarts writers.

    The owner and all local clients are locked together. MySQL read_only persists
    across a database restart, while administrative restore/migration sessions can
    still write. Unknown writers cause a refusal, never an automatic disconnect.
    """

    def __init__(self, owner, operation, *, assume_yes=False):
        self.owner = owner
        self.operation = operation
        self.assume_yes = assume_yes
        self.record = owner / service_control.MAINTENANCE_RECORD
        self.locks = ExitStack()
        self.journal = None
        self.members = []

    def __enter__(self):
        try:
            self.prepare()
            return self
        except BaseException:
            self.locks.close()
            raise

    def __exit__(self, kind, error, traceback):
        if error is not None and self.record.exists():
            print('Database maintenance remains fenced. Correct the problem and rerun the same '
                  + self.operation + ' command.', flush=True)
        self.locks.close()

    def prepare(self):
        """Record original service/map state before stopping any managed writer."""
        for directory in sorted(self.owner.parent.iterdir()):
            if not (directory / 'installation.json').is_file():
                continue
            settings = install.load_installation(directory, allow_other_release=True)
            if directory == self.owner or settings['database'].get('owner_instance') == str(self.owner):
                self.members.append((directory, settings))
        if not any(directory == self.owner for directory, settings in self.members):
            raise RuntimeError('Database owner is not an installed instance')
        for directory, settings in self.members:
            self.locks.enter_context(operation_lock(directory / '.setup.lock'))
            install.verify_managed_files(directory, settings)
            if (directory / 'pending-configuration.json').exists():
                raise RuntimeError('Apply or discard pending configuration before database maintenance')
        self.settings = install.load_installation(self.owner, allow_other_release=True)
        if self.settings['database']['mode'] != 'new':
            raise RuntimeError('Database maintenance must run on its owner')
        if self.record.exists():
            self.journal = read_json(self.record)
            if self.journal.get('operation') != self.operation or self.journal.get('owner') != str(self.owner):
                raise RuntimeError('A different database maintenance operation is unfinished')
            if set(self.journal['members']) != {str(directory) for directory, settings in self.members}:
                raise RuntimeError('Database membership changed during maintenance; preserve the fence')
        else:
            states = {}
            for directory, settings in self.members:
                service_control.require_available(directory)
                active = service_control.active_game(directory, settings)
                count = len(active['players'])
                print(settings['name'] + ': ' + str(count) + ' connected player(s).', flush=True)
                if count and not self.assume_yes and not ask_yes_no('Disconnect these players for maintenance?', False):
                    raise RuntimeError('Maintenance cancelled before any service was stopped')
                services = install.compose(directory, settings, 'ps', '--status', 'running', '--services').splitlines()
                states[str(directory)] = {'active': active, 'services': services}
            self.journal = {'owner': str(self.owner), 'operation': self.operation, 'members': states}
            save_json(self.record, self.journal)
        for directory, settings in self.members:
            if directory != self.owner:
                save_json(directory / service_control.MAINTENANCE_RECORD,
                          {'owner': str(self.owner), 'operation': self.operation})
        self.stop_writers()
        install.compose(self.owner, self.settings, 'up', '-d', '--wait', 'db', timeout=360)
        with install.database_client(self.owner, self.settings, administrator=True, schema='information_schema') as db:
            if 'read_only' not in self.journal:
                read_only, super_read_only = db.query('SELECT @@global.read_only, @@global.super_read_only;').split('\t')
                if super_read_only != '0':
                    raise RuntimeError('Database was already super_read_only; resolve its existing maintenance first')
                self.journal['read_only'] = int(read_only)
                save_json(self.record, self.journal)
            db.query('SET PERSIST read_only=ON;')
            source.require_no_other_writers(db)

    def stop_writers(self):
        for directory, settings in self.members:
            install.compose(directory, settings, 'stop', 'server', *install.optional_services(settings), timeout=120)

    def resume(self, start_services):
        """Release the SQL fence only after data verification; re-fence if activation fails."""
        # Shared clients have separate accounts, so every one needs new table/routine grants.
        with install.database_client(self.owner, self.settings, administrator=True) as db:
            for directory, old_settings in self.members:
                settings = install.load_installation(directory, allow_other_release=True)
                install.provision_game_account(db, settings)
                if settings.get('website'):
                    import website
                    website.provision(db, settings)
        with install.database_client(self.owner, self.settings, administrator=True, schema='information_schema') as db:
            db.query('SET PERSIST read_only=' + str(self.journal['read_only']) + ';')
        try:
            for directory, old_settings in self.members:
                settings = install.load_installation(directory, allow_other_release=True)
                previous = self.journal['members'][str(directory)]
                if 'server' in previous['services']:
                    start_services(directory, settings, recreate=True, active_map=previous['active']['map'])
                    install.check_ready(directory, settings)
                else:
                    optional = [name for name in install.optional_services(settings) if name in previous['services']]
                    if optional:
                        install.compose(directory, settings, 'up', '-d', '--no-deps', '--force-recreate', *optional)
                    if settings.get('website'):
                        import website
                        website.start(directory, settings)
            if 'db' not in self.journal['members'][str(self.owner)]['services']:
                install.compose(self.owner, self.settings, 'stop', 'db')
        except BaseException:
            self.stop_writers()
            with install.database_client(self.owner, self.settings, administrator=True, schema='information_schema') as db:
                db.query('SET PERSIST read_only=ON;')
            raise
        for directory, settings in self.members:
            if directory != self.owner:
                (directory / service_control.MAINTENANCE_RECORD).unlink(missing_ok=True)
        self.record.unlink()
