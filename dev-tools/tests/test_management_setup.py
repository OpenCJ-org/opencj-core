"""SSH hardening, settings changes and switched-off features: paths that must never lock out an operator."""

from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'setup'))
import host_plan
import manage
import ssh_hardening


class PortMoveTests(unittest.TestCase):
    """The old SSH port may close only after a real login on the new port was seen."""

    def run_move(self, *, login_seen):
        plan = {'ssh_hardening': {'new_port': 2222}}
        listened = []
        firewall_calls = []
        ports = {'value': [22]}

        def listen_on(new_ports):
            listened.append(list(new_ports))
            ports['value'] = list(new_ports)

        with patch.object(ssh_hardening, 'current_ssh_ports', lambda: ports['value']), \
                patch.object(ssh_hardening, 'listen_on', listen_on), \
                patch.object(ssh_hardening, 'listening_ssh_ports', lambda: set(ports['value'])), \
                patch.object(ssh_hardening, 'established_on', lambda port: login_seen), \
                patch.object(ssh_hardening, 'prompt', lambda label, default='': default), \
                patch.object(ssh_hardening, 'administrator', lambda: None), \
                patch('dns_guide.public_addresses', lambda plan=None: {'A': [], 'AAAA': []}), \
                patch('builtins.print'):
            ssh_hardening.move_port(plan, 2222,
                                    lambda extra_ssh_ports=(): firewall_calls.append(list(extra_ssh_ports)))
        return plan['ssh_hardening'], listened, firewall_calls

    def test_old_port_stays_open_without_a_verified_login(self):
        hardening, listened, firewall_calls = self.run_move(login_seen=False)
        self.assertEqual(listened, [[22, 2222]], 'SSH must keep listening on the old port')
        self.assertEqual(hardening['ports'], [22, 2222])
        self.assertFalse(hardening.get('port_moved'))
        self.assertEqual(firewall_calls, [[2222]], 'The new port must be opened before SSH uses it')

    def test_old_port_closes_after_a_verified_login(self):
        hardening, listened, firewall_calls = self.run_move(login_seen=True)
        self.assertEqual(listened, [[22, 2222], [2222]])
        self.assertTrue(hardening['port_moved'])
        self.assertEqual(firewall_calls[0], [2222], 'The new port opens first')

    def test_finished_move_is_not_repeated(self):
        plan = {'ssh_hardening': {'new_port': 2222, 'port_moved': True}}
        with patch.object(ssh_hardening, 'listen_on') as listen_on, \
                patch.object(ssh_hardening, 'current_ssh_ports', lambda: [2222]):
            ssh_hardening.move_port(plan, 2222, lambda extra_ssh_ports=(): None)
        listen_on.assert_not_called()

    def test_key_only_needs_an_installed_key(self):
        with patch.object(ssh_hardening, 'administrator', lambda: None), \
                patch.object(ssh_hardening, 'managed') as managed:
            with self.assertRaisesRegex(RuntimeError, 'nothing was changed'):
                ssh_hardening.apply_key_only(True)
        managed.assert_not_called()


class KeyLoginTests(unittest.TestCase):
    """Password logins go only after a real login with the administrator's key was seen."""
    account = type('Account', (), {'pw_name': 'admin', 'pw_dir': '/home/admin'})()

    def wait(self, *, key_present, logins, interactive=True, answers=3):
        presses = iter([''] * answers)
        printed = []
        with patch.object(ssh_hardening, 'has_authorized_key', lambda account: key_present()), \
                patch.object(ssh_hardening, 'key_login_seen', lambda account, since: logins()), \
                patch.object(ssh_hardening, 'key_instructions', lambda account: 'how to add a key'), \
                patch.object(ssh_hardening.sys.stdin, 'isatty', lambda: interactive), \
                patch.object(ssh_hardening, 'prompt', lambda label, default='': next(presses)), \
                patch('builtins.print', lambda *parts, **options: printed.append(' '.join(map(str, parts)))):
            ssh_hardening.wait_for_key_login(self.account)
        return printed

    def test_earlier_key_login_needs_no_waiting(self):
        printed = self.wait(key_present=lambda: True, logins=lambda: True, answers=0)
        self.assertIn('was seen', printed[0])

    def test_waits_until_the_key_is_added_and_used(self):
        state = {'checks': 0}

        def logins():
            state['checks'] += 1
            # Not seen before the instructions, nor after the first Enter; seen after the second.
            return state['checks'] >= 3
        printed = self.wait(key_present=lambda: True, logins=logins)
        self.assertIn('how to add a key', printed)
        self.assertTrue(any('no login with it was seen' in line for line in printed))
        self.assertIn('Key login seen. Password logins will be switched off.', printed)

    def test_unattended_run_without_key_login_stops(self):
        with self.assertRaisesRegex(RuntimeError, 'cannot be switched off safely'):
            self.wait(key_present=lambda: False, logins=lambda: False, interactive=False)

    def test_plan_cannot_keep_passwords(self):
        with self.assertRaisesRegex(ValueError, 'key_only must be true'):
            ssh_hardening.validate_ssh_hardening({'key_only': False})
        self.assertTrue(ssh_hardening.validate_ssh_hardening({'fail2ban': True})['key_only'])


class ListenTests(unittest.TestCase):
    """SSH must keep answering over IPv4 and IPv6; a failed change is undone."""

    def test_socket_configuration_lists_ipv4_and_ipv6_for_every_port(self):
        lines = ssh_hardening.socket_listen_lines([22, 2222]).splitlines()
        for port in (22, 2222):
            self.assertIn('ListenStream=0.0.0.0:' + str(port), lines, 'IPv4 clients would be locked out')
            self.assertIn('ListenStream=[::]:' + str(port), lines)
        self.assertNotIn('ListenStream=22', lines, 'A bare port is IPv6-only with Ubuntu\'s BindIPv6Only')

    def test_failed_change_restores_the_previous_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            port_file = Path(temporary) / 'port.conf'
            socket_file = Path(temporary) / 'socket.conf'
            port_file.write_text(ssh_hardening.MARKER + 'Port 22\n')
            with patch.object(ssh_hardening, 'SSHD_PORT_DROP_IN', port_file), \
                    patch.object(ssh_hardening, 'SOCKET_DROP_IN', socket_file), \
                    patch.object(ssh_hardening, 'socket_activated', lambda: True), \
                    patch.object(ssh_hardening, 'run'), \
                    patch.object(ssh_hardening.sshd, 'sshd'), \
                    patch.object(ssh_hardening.sshd, 'reload'), \
                    patch.object(ssh_hardening, 'current_ssh_ports', lambda: [2222]), \
                    patch.object(ssh_hardening.sshd, 'answers_on', lambda port: False):
                with self.assertRaisesRegex(RuntimeError, 'does not answer'):
                    ssh_hardening.listen_on([2222])
            self.assertEqual(port_file.read_text(), ssh_hardening.MARKER + 'Port 22\n')
            self.assertFalse(socket_file.exists(), 'The new socket file must be removed again')


class RemoteDatabaseTests(unittest.TestCase):
    """Sharing a database with another machine stays switched off until it has been tested."""

    def test_wizard_does_not_offer_remote_databases(self):
        self.assertFalse(host_plan.REMOTE_DATABASE_ENABLED)
        self.assertNotIn('owner', host_plan.DATABASE_CHOICES)
        self.assertNotIn('existing', host_plan.DATABASE_CHOICES)

    def test_plan_with_a_remote_database_is_refused(self):
        for database in ({'mode': 'existing'}, {'mode': 'owner'}, {'mode': 'new', 'publish_port': 3306}):
            plan = {'instances': [{'name': 'main-us', 'port': 28960, 'database': database}]}
            with self.subTest(database=database), self.assertRaisesRegex(ValueError, 'switched off'):
                host_plan.validate_plan(plan)


class ConfigureTests(unittest.TestCase):
    settings = {'name': 'map-test', 'hostname': 'OpenCJ map-test', 'port': 28962, 'address': '', 'slots': 32,
                'public': False, 'map': 'mp_killhouse', 'downloads': {'mode': 'in-game'}, 'discord': {'enabled': False},
                'join_password': 'abc123', 'rcon_password': 'rconpass1',
                # A server sharing another database: no backup/pruning questions, no website.
                'database': {'mode': 'existing'}}

    def collect(self, answers):
        replies = iter(answers)
        with patch('builtins.input', lambda label: next(replies)), patch('builtins.print'):
            return manage.collect_changes(dict(self.settings), other_ports={28960, 28961})

    def test_keeping_every_default_changes_nothing(self):
        # name, port, address, slots, public, map, downloads?, Discord?, join password, rcon password
        self.assertEqual(self.collect([''] * 10), self.settings)

    def test_port_of_another_server_is_refused_and_asked_again(self):
        changed = self.collect(['', '28960', '28963', '', '', '', '', '', '', '', ''])
        self.assertEqual(changed['port'], 28963)

    def test_address_can_be_set_and_cleared(self):
        changed = self.collect(['', '', 'test.opencj.org', '', '', '', '', '', '', ''])
        self.assertEqual(changed['address'], 'test.opencj.org')
        self.settings = {**self.settings, 'address': 'test.opencj.org'}
        self.assertEqual(self.collect(['', '', 'none', '', '', '', '', '', '', ''])['address'], '')

    def test_going_public_removes_the_join_password(self):
        # A public server has no join password, so that question is skipped.
        changed = self.collect(['', '', '', '', 'yes', '', 'no', 'no', ''])
        self.assertTrue(changed['public'])
        self.assertEqual(changed['join_password'], '')

    def test_passwords_can_be_typed_regenerated_or_kept(self):
        changed = self.collect(['', '', '', '', '', '', 'no', 'no', 'short', 'MyJoinPass', 'new'])
        self.assertEqual(changed['join_password'], 'MyJoinPass', 'A too-short password must be asked again')
        self.assertNotEqual(changed['rcon_password'], 'rconpass1')
        self.assertGreaterEqual(len(changed['rcon_password']), 16)


if __name__ == '__main__':
    unittest.main()
