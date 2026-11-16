import unittest
from unittest.mock import patch

from test_media_bridge import snapshot
import test_multi_timers as fixtures


class LoopOutputTests(unittest.TestCase):
    setUp = fixtures.MultiTimerTests.setUp
    new = fixtures.MultiTimerTests.new
    send = fixtures.MultiTimerTests.send
    statuses = fixtures.MultiTimerTests.statuses

    def test_loop_transitions_policies_and_raw_snapshot(self):
        for policy in ('stop', 'keep_last'):
            with self.subTest(policy=policy):
                self.bridge.config['auxiliary_timers'][1]['inactive_policy'] = policy
                self.send(snapshot(loop=False, shuffle=True))
                self.assertEqual(self.statuses()[2]['output_status'], 'synced')
                self.send(snapshot(loop=True, shuffle=True))
                self.assertEqual(self.statuses()[1]['output_status'], 'synced')
                self.assertEqual(self.statuses()[2]['output_status'], 'playlist_looping')
                self.assertEqual(self.fake.slots[2].timer['playback'], 'stop' if policy == 'stop' else 'pause')
                self.assertEqual(self.bridge.status()['playlist_remaining_ms'], 9000)
                self.assertEqual(self.bridge._timers[2]['owned'], policy == 'keep_last')
                self.fake.calls.clear()
                self.send(snapshot(loop=True))
                self.assertFalse(any('/auxtimer/2/' in p for p in self.fake.calls))
                self.send(snapshot(loop=False))
                self.assertEqual(self.statuses()[2]['output_status'], 'synced')
                self.assertEqual(self.fake.slots[2].timer['playback'], 'start')

    def test_legacy_playlist_and_disconnect(self):
        self.bridge.config = {'enabled': True, 'timer': {'media_timer_source': 'playlist',
            'ontime_output': 'auxiliary_timer', 'aux_timer_index': 1, 'inactive_policy': 'stop'}}
        self.send(snapshot(loop=False))
        self.send(snapshot(loop=True))
        self.assertEqual(self.bridge.status()['output_status'], 'playlist_looping')
        self.assertEqual(self.fake.slots[1].timer['playback'], 'stop')
        self.bridge.reset_session('reconnect')
        self.bridge.process_outputs()
        self.assertEqual(self.bridge.status()['output_status'], 'waiting_for_snapshot')

    def test_zero_unknown_and_loop(self):
        for loop, known, expected in ((False, True, 'synced'), (True, True, 'playlist_looping'),
                                      (True, False, 'playlist_looping'), (False, False, 'unknown_remaining')):
            value = snapshot(loop=loop, remaining_ms=0, playlist_remaining_ms=0,
                             playlist_remaining_known=known)
            if not known:
                del value['playlist_remaining_ms']
            self.send(value)
            self.assertEqual(self.statuses()[1]['output_status'], 'synced')
            self.assertEqual(self.statuses()[2]['output_status'], expected)

    def test_templates_preserve_file_current_and_literal(self):
        self.bridge.config['timer'] = {'ontime_output': 'secondary_message', 'media_timer_source': 'playlist',
            'secondary_message_template': 'Live {current_file} {remaining_hhmmss} {playlist_remaining_hhmmss}'}
        with patch('media_bridge.time.monotonic', side_effect=lambda: self.seq * 2 + 100):
            for loop, known, expected in ((False, True, '00:00:00'), (True, True, '--:--'),
                                          (False, True, '00:00:00'), (False, False, '--:--')):
                value = snapshot(loop=loop, current_file='clip.mp4', remaining_ms=0,
                                 playlist_remaining_ms=0, playlist_remaining_known=known)
                if not known:
                    del value['playlist_remaining_ms']
                self.send(value)
                self.assertEqual(self.bridge._last_message, f'Live clip.mp4 00:00:00 {expected}')

    def test_unknown_current_file_stays_unknown_during_loop(self):
        value = snapshot(loop=True, remaining_known=False)
        del value['remaining_ms']
        self.send(value)
        self.assertEqual(self.statuses()[1]['output_status'], 'unknown_remaining')
        self.assertEqual(self.statuses()[2]['output_status'], 'playlist_looping')
        self.assertFalse(any('/auxtimer/' in p for p in self.fake.calls))

    def test_dry_run_loop_does_not_mutate_ontime(self):
        self.bridge.dry_run = True
        for loop in (False, True, False):
            self.send(snapshot(loop=loop))
        self.assertEqual(self.fake.calls, [])
