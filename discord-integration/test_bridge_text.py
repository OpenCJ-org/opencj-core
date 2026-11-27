"""Parsing, escaping and configuration rules of the Discord bridge (standard library only)."""

import unittest

from announcements import format_challenge_completed, format_server_record
from bridge_config import parse_config
from opencj_events import (FIELD_SEPARATOR, ChallengeCompletedEvent, MapStartedEvent, PlayerCountChangedEvent,
                           PlayerMessageEvent, PlayerRenamedEvent, RunFinishedEvent, ServerRecordEvent,
                           parse_game_event)
from util import get_clean_name, to_discord_text, to_game_text

SOCKET_ENVIRONMENT = {'OPENCJ_DISCORD_SOCKET': '/run/opencj-discord/events.sock'}
FIXTURE_GUILD_ID = '100000000000000001'
FIXTURE_CHANNEL_ID = '100000000000000002'
FIXTURE_USER_ID = 100000000000000003


def game_line(*fields):
    return FIELD_SEPARATOR.join(str(field) for field in fields)


class GameEventParsingTests(unittest.TestCase):
    def test_semicolons_stay_inside_names_and_messages(self):
        event = parse_game_event(game_line(0, 'a;b', 'hi; there'))
        self.assertEqual(event, PlayerMessageEvent('a;b', 'hi; there'))

    def test_run_finished_keeps_every_field(self):
        event = parse_game_event(game_line(5, 'Runner', 42, '1:02.345', 'mp_fixture', 'main;alt'))
        self.assertEqual(event, RunFinishedEvent('Runner', 42, '1:02.345', 'mp_fixture', 'main;alt'))

    def test_renamed_event_is_supported(self):
        event = parse_game_event(game_line(6, 'Old', 'New'))
        self.assertEqual(event, PlayerRenamedEvent('Old', 'New'))

    def test_malformed_lines_are_ignored_without_raising(self):
        with self.assertLogs('opencj_events', level='WARNING'):
            self.assertIsNone(parse_game_event('lo world'))
            self.assertIsNone(parse_game_event(game_line(2, 'many')))
            self.assertIsNone(parse_game_event(game_line(99, 'x')))
            self.assertIsNone(parse_game_event(game_line(5, 'Runner', 'notanumber', 't', 'm', 'r')))

    def test_color_codes_and_controls_are_removed(self):
        self.assertEqual(parse_game_event(game_line(1, '^1mp_^2fixture')), MapStartedEvent('mp_fixture'))
        self.assertEqual(get_clean_name('^1A\x01B'), 'A B')
        self.assertIsNone(get_clean_name('^1x'))

    def test_player_count(self):
        self.assertEqual(parse_game_event(game_line(2, 0)), PlayerCountChangedEvent(0))

    def test_server_record_keeps_every_field(self):
        event = parse_game_event(game_line(7, '^1Runner', 'mp_fixture', 'main', '125 FPS, checkpoints',
                                           '1:02.345', 3, 'time: 0:00.512 faster'))
        expected = ServerRecordEvent('Runner', 'mp_fixture', 'main', '125 FPS, checkpoints', '1:02.345', 3,
                                     'time: 0:00.512 faster')
        self.assertEqual(event, expected)

    def test_challenge_without_time_limit(self):
        event = parse_game_event(game_line(8, 'Runner', 'mp_fixture', 'Hard', 6, 60, ''))
        self.assertEqual(event, ChallengeCompletedEvent('Runner', 'mp_fixture', 'Hard', 6, 60, None))

    def test_malformed_record_and_challenge_lines_are_ignored(self):
        record_without_improvement = game_line(7, 'Runner', 'mp_fixture', 'main', 'cat', '1:00', 3)
        record_with_negative_rpgs = game_line(7, 'Runner', 'mp_fixture', 'main', 'cat', '1:00', -1, 'x')
        challenge_with_tier_zero = game_line(8, 'Runner', 'mp_fixture', 'Hard', 0, 60, '')
        challenge_with_text_tier = game_line(8, 'Runner', 'mp_fixture', 'Hard', 'six', 60, '')
        with self.assertLogs('opencj_events', level='WARNING'):
            self.assertIsNone(parse_game_event(record_without_improvement))
            self.assertIsNone(parse_game_event(record_with_negative_rpgs))
            self.assertIsNone(parse_game_event(challenge_with_tier_zero))
            self.assertIsNone(parse_game_event(challenge_with_text_tier))


class AnnouncementTests(unittest.TestCase):
    def test_server_record_message(self):
        event = ServerRecordEvent('Run*ner', 'mp_fixture', 'main', '125 FPS, checkpoints', '1:02.345', 1,
                                  'time: 0:00.512 faster; RPGs: 2 fewer')
        expected = ('\U0001F3C6 **Run\\*ner** set a server record on ``mp_fixture - main`` '
                    '(125 FPS, checkpoints): ``1:02.345`` with 1 RPG (time: 0:00.512 faster; RPGs: 2 fewer)')
        self.assertEqual(format_server_record(event), expected)

    def test_route_backticks_cannot_end_the_code_span(self):
        event = ServerRecordEvent('Runner', 'mp_fixture', 'a``b', 'Any FPS, any%', '0:59.000', 0, 'RPGs: 1 fewer')
        self.assertIn('``mp_fixture - a\'\'b``', format_server_record(event))
        self.assertIn('with 0 RPGs', format_server_record(event))

    def test_challenge_messages(self):
        untimed = ChallengeCompletedEvent('Runner', 'mp_fixture', 'Hard', 6, 60, None)
        self.assertEqual(format_challenge_completed(untimed),
                         '\U0001F3AF **Runner** completed the challenge ``mp_fixture - Hard`` (Tier 6, +60 pts)')
        timed = ChallengeCompletedEvent('Runner', 'mp_fixture', 'Hard', 10, 100, '1:00:00')
        self.assertTrue(format_challenge_completed(timed).endswith('(Tier 10, +100 pts, within 1:00:00)'))


class DiscordTextTests(unittest.TestCase):
    def test_mass_and_raw_mentions_are_plain_text(self):
        escaped = to_discord_text('@everyone @here <@123456789012345678> <@&123456789012345678>')
        self.assertNotIn('<@', escaped)
        self.assertIn('\\@everyone', escaped)
        self.assertIn('\\@here', escaped)

    def test_markdown_is_escaped(self):
        self.assertEqual(to_discord_text('**bold** [x](http://e)'), '\\*\\*bold\\*\\* \\[x\\]\\(http://e\\)')

    def test_only_allowed_users_become_mentions(self):
        allowed = {'admin': FIXTURE_USER_ID}
        text = to_discord_text('hi @Admin and @someone', allowed)
        self.assertEqual(text, 'hi <@' + str(FIXTURE_USER_ID) + '> and \\@someone')

    def test_game_text_cannot_break_the_server_command(self):
        self.assertEqual(to_game_text('say "hi"\\ \n^1x é\U0001F600'), "say 'hi' x")


class ConfigTests(unittest.TestCase):
    def config_text(self, *extra_lines):
        lines = ['# bridge', 'token=fixture.token', '',
                 'guildid=' + FIXTURE_GUILD_ID, '', 'channelid=' + FIXTURE_CHANNEL_ID + '\n', *extra_lines]
        return '\n'.join(lines) + '\n'

    def test_blank_lines_comments_and_line_breaks_are_accepted(self):
        config = parse_config(self.config_text(), SOCKET_ENVIRONMENT)
        self.assertEqual(config.token, 'fixture.token')
        self.assertEqual(config.channel_id, int(FIXTURE_CHANNEL_ID))
        self.assertEqual(config.mentionable_user_ids, ())

    def test_mentionable_users(self):
        config = parse_config(self.config_text('mentionuserids=' + str(FIXTURE_USER_ID) + ', '), SOCKET_ENVIRONMENT)
        self.assertEqual(config.mentionable_user_ids, (FIXTURE_USER_ID,))

    def test_invalid_configuration_is_rejected(self):
        with self.assertRaises(ValueError):
            parse_config(self.config_text('mentionuserids=abc'), SOCKET_ENVIRONMENT)
        with self.assertRaises(ValueError):
            parse_config(self.config_text('colour=red'), SOCKET_ENVIRONMENT)
        with self.assertRaises(ValueError):
            parse_config(self.config_text(), {})
        with self.assertRaises(ValueError):
            parse_config('token=x\n', SOCKET_ENVIRONMENT)


if __name__ == '__main__':
    unittest.main()
