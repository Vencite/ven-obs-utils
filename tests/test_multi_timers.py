import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError

from test_media_bridge import FakeOntime, snapshot
from media_bridge import MediaBridge, unavailable


class MultiOntime:
    def __init__(self):
        self.slots = {i: FakeOntime() for i in (1, 2, 3)}
        self.calls = []
        self.fail = None
        self.before = None

    def __call__(self, path):
        self.calls.append(path)
        if self.before:
            self.before(path)
        if path == self.fail:
            raise HTTPError('http://fake', 503, 'unavailable', None, None)
        if path == '/api/poll':
            return {'payload': {f'auxtimer{i}': copy.deepcopy(slot.timer) for i, slot in self.slots.items()}}
        for i in self.slots:
            if path.startswith(f'/api/auxtimer/{i}/'):
                return self.slots[i](path.replace(f'/api/auxtimer/{i}/', '/api/auxtimer/1/'))
        return self.slots[1](path)


def config():
    return {'enabled': True, 'auxiliary_timers': [
        {'enabled': True, 'aux_timer_index': 1, 'media_timer_source': 'current_item', 'inactive_policy': 'stop'},
        {'enabled': True, 'aux_timer_index': 2, 'media_timer_source': 'playlist', 'inactive_policy': 'keep_last'}]}


class MultiTimerTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / 'owner.json'
        self.fake = MultiOntime()
        self.bridge = self.new()
        self.bridge.reset_session('s')
        self.seq = 0

    def new(self, cfg=None, dry=False):
        return MediaBridge(cfg or config(), dry, self.fake, ownership_path=self.path, target_id='host')

    def send(self, state=None):
        self.seq += 1
        self.bridge.ingest({'session': 's', 'sequence': self.seq, 'snapshot': state or snapshot()})
        self.bridge.process_outputs()

    def statuses(self, bridge=None):
        return {r['aux_timer_index']: r for r in (bridge or self.bridge).status()['auxiliary_timers']}

    def test_two_times_and_stable_progress(self):
        self.send()
        self.assertEqual([self.fake.slots[i].timer['current'] for i in (1, 2)], [3000, 9000])
        self.assertEqual(self.fake.calls.count('/api/poll'), 1)
        self.assertEqual(json.loads(self.path.read_text())['indices'], [1, 2])
        self.fake.calls.clear()
        self.fake.slots[1].timer['current'] = 2000
        self.fake.slots[2].timer['current'] = 8000
        self.send(snapshot(remaining_ms=2000, playlist_remaining_ms=8000))
        self.assertEqual(self.fake.calls, ['/api/poll'])
        self.assertEqual(self.statuses()[3]['output_status'], 'disabled')

    def test_next_seek_speed_shuffle(self):
        self.send()
        for revision, values in enumerate([
                {'current_item_id': 'next', 'remaining_ms': 6000, 'playlist_remaining_ms': 8000},
                {'remaining_ms': 1000, 'playlist_remaining_ms': 3000},
                {'speed_percent': 200, 'remaining_ms': 500, 'playlist_remaining_ms': 1500},
                {'shuffle': True, 'loop': False, 'remaining_ms': 2000, 'playlist_remaining_ms': 4000}], 2):
            self.send(snapshot(snapshot_revision=revision, **values))
            self.assertEqual(self.fake.slots[1].timer['current'], values['remaining_ms'])
            self.assertEqual(self.fake.slots[2].timer['current'], values['playlist_remaining_ms'])

    def test_long_pause_resume_unknown_playlist(self):
        clock = [100.0]
        with patch('media_bridge.time.monotonic', side_effect=lambda: clock[0]):
            self.send(snapshot(state='paused'))
            self.fake.calls.clear()
            for n in range(1, 301):
                clock[0] += 1
                self.seq += 1
                self.bridge.heartbeat({'session': 's', 'sequence': self.seq})
                self.bridge.process_outputs()
            self.assertEqual(self.fake.calls, [])
            self.send(snapshot(snapshot_revision=2))
            self.assertEqual([self.fake.slots[i].timer['playback'] for i in (1, 2)], ['start', 'start'])
            value = snapshot(snapshot_revision=3, playlist_remaining_known=False)
            del value['playlist_remaining_ms']
            self.send(value)
            self.assertEqual(self.fake.slots[1].timer['playback'], 'start')
            self.assertEqual(self.fake.slots[2].timer['playback'], 'pause')
            self.assertEqual(self.statuses()[2]['output_status'], 'unknown_remaining')
            self.send(snapshot(snapshot_revision=4))
            self.assertEqual(self.fake.slots[2].timer['playback'], 'start')

    def test_slot_error_isolated_and_retry(self):
        self.fake.fail = '/api/auxtimer/1/start'
        self.send()
        self.assertEqual(self.statuses()[1]['output_status'], 'error')
        self.assertEqual(self.statuses()[2]['output_status'], 'synced')
        self.fake.fail = None
        self.fake.calls.clear()
        self.send()
        self.assertEqual(self.statuses()[1]['output_status'], 'synced')
        self.assertFalse(any(p.startswith('/api/auxtimer/2/') for p in self.fake.calls), 'Retrying one slot must not restart the healthy timer')

    def test_stop_keep_last_and_shutdown(self):
        self.send()
        self.send(unavailable('disconnected'))
        self.assertEqual([self.fake.slots[i].timer['playback'] for i in (1, 2)], ['stop', 'pause'])
        self.assertEqual(json.loads(self.path.read_text())['indices'], [2])
        self.send(snapshot(snapshot_revision=2))
        self.bridge.close()
        self.assertEqual([self.fake.slots[i].timer['playback'] for i in (1, 2)], ['stop', 'stop'])
        self.assertFalse(self.path.exists())

    def test_crash_and_partial_recovery_does_not_block_other_slot(self):
        self.send()
        self.fake.slots[2].timer['playback'] = 'stop'
        restarted = self.new()
        restarted.reset_session('new')
        restarted.ingest({'session': 'new', 'sequence': 1, 'snapshot': snapshot()})
        self.fake.calls.clear()
        restarted.process_outputs()
        self.assertEqual(self.statuses(restarted)[1]['output_error'], 'timer_recovery_required')
        self.assertEqual(self.statuses(restarted)[2]['output_status'], 'synced')
        self.assertFalse(any(p.startswith('/api/auxtimer/1/') for p in self.fake.calls))
        self.assertEqual(json.loads(self.path.read_text())['indices'], [1, 2])

    def test_legacy_journal_retained_when_second_slot_acquired(self):
        self.path.write_text(json.dumps({'target': 'host', 'index': 1}))
        self.fake.slots[1].timer['playback'] = 'start'
        restarted = self.new()
        restarted.reset_session('s')
        restarted.ingest({'session': 's', 'sequence': 1, 'snapshot': snapshot()})
        restarted.process_outputs()
        self.assertEqual(json.loads(self.path.read_text())['indices'], [1, 2])
        self.assertEqual(self.statuses(restarted)[1]['output_status'], 'error')
        self.assertEqual(self.statuses(restarted)[2]['output_status'], 'synced')

    def test_journal_failure_before_second_mutation_and_shutdown_error_isolation(self):
        import media_bridge
        write = media_bridge._atomic_write
        def save(path, text):
            if json.loads(text).get('indices') == [1, 2]:
                raise OSError('disk full')
            write(path, text)
        with patch('media_bridge._atomic_write', side_effect=save):
            self.send()
        self.assertEqual(self.fake.slots[1].timer['playback'], 'start')
        self.assertEqual(self.fake.slots[2].timer['playback'], 'stop')
        self.send()
        self.fake.fail = '/api/auxtimer/1/stop'
        self.bridge.close()
        self.assertEqual(self.fake.slots[2].timer['playback'], 'stop')
        self.assertEqual(json.loads(self.path.read_text())['indices'], [1])

    def test_dry_run_and_single_stage_source_with_secondary(self):
        cfg = config()
        cfg['stage_timer_source'] = 'aux2'
        cfg['timer'] = {'ontime_output': 'secondary_message', 'media_timer_source': 'playlist',
                        'secondary_message_template': '{current_file}'}
        bridge = self.new(cfg, dry=True)
        bridge.reset_session('s')
        bridge.ingest({'session': 's', 'sequence': 1, 'snapshot': snapshot()})
        bridge.process_outputs()
        bridge.close()
        self.assertEqual(self.fake.calls, [])
        bridge = self.new(cfg)
        bridge.reset_session('s')
        bridge.ingest({'session': 's', 'sequence': 1, 'snapshot': snapshot()})
        bridge.process_outputs()
        self.assertEqual([p for p in self.fake.calls if p.startswith('/api/message/timer?')],
                         ['/api/message/timer?secondarySource=aux2'])
        self.assertTrue(any(p.startswith('/api/message/secondary/') for p in self.fake.calls))

    def test_duplicate_slots_rejected_and_disabled_fields_ignored(self):
        cfg = config()
        cfg['auxiliary_timers'][1]['aux_timer_index'] = 1
        with self.assertRaises(ValueError):
            self.new(cfg)
        cfg['enabled'] = False
        self.new(cfg)
        cfg = config()
        cfg['auxiliary_timers'].append({'enabled': False, 'aux_timer_index': 'invalid', 'media_timer_source': None})
        self.new(cfg)

    def test_shared_swift_python_validation_fixtures(self):
        from media_bridge import validate_config
        for case in json.loads((Path(__file__).parent / 'fixtures/media_timer_configs.json').read_text()):
            with self.subTest(case=case['name']):
                if case['valid']:
                    validate_config(case['media'])
                else:
                    with self.assertRaises(ValueError):
                        validate_config(case['media'])

    def test_foreign_slot_does_not_block_independent_slot(self):
        self.fake.slots[1].timer['playback'] = 'start'
        self.send()
        self.assertEqual(self.statuses()[1]['output_error'], 'aux_timer_in_use')
        self.assertEqual(self.statuses()[2]['output_status'], 'synced')
        self.assertFalse(any(p.startswith('/api/auxtimer/1/') for p in self.fake.calls))
        self.bridge.close()
        self.assertEqual(self.fake.slots[1].timer['playback'], 'start')
        self.assertFalse(self.path.exists())

    def test_crash_between_commands_has_durable_intents_for_both_slots(self):
        def before(path):
            if path.startswith('/api/auxtimer/'):
                index = int(path.split('/')[3])
                self.assertIn(index, json.loads(self.path.read_text())['indices'])
            if path == '/api/auxtimer/2/direction/count-down':
                raise SystemExit('simulated SIGKILL')
        self.fake.before = before
        with self.assertRaises(SystemExit):
            self.send()
        self.assertEqual(json.loads(self.path.read_text())['indices'], [1, 2])
        self.assertEqual(self.fake.slots[1].timer['playback'], 'start')
        self.fake.before = None
        self.fake.calls.clear()
        restarted = self.new()
        restarted.reset_session('restart')
        restarted.ingest({'session': 'restart', 'sequence': 1, 'snapshot': snapshot()})
        restarted.process_outputs()
        self.assertEqual(self.statuses(restarted)[1]['output_error'], 'timer_recovery_required')
        self.assertEqual(self.statuses(restarted)[2]['output_status'], 'synced')
        self.assertFalse(any(p.startswith('/api/auxtimer/1/') for p in self.fake.calls))

    def test_new_session_during_first_slot_prevents_second_old_batch(self):
        def before(path):
            if path == '/api/auxtimer/1/duration/3000':
                self.bridge.reset_session('new')
        self.fake.before = before
        self.send()
        self.assertFalse(any(p.startswith('/api/auxtimer/2/') for p in self.fake.calls))
        self.assertNotIn('/api/auxtimer/1/start', self.fake.calls)
        self.fake.before = None
        self.bridge.process_outputs()
        self.assertFalse(self.path.exists())

    def test_uncertain_durable_write_is_preserved_when_next_slot_starts(self):
        import os
        import stat
        fsync = os.fsync
        def uncertain(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode) and json.loads(self.path.read_text())['indices'] == [1]:
                raise OSError('directory fsync after replace')
            fsync(fd)
        with patch('media_bridge.os.fsync', side_effect=uncertain):
            self.send()
        self.assertEqual(json.loads(self.path.read_text())['indices'], [1, 2])
        self.assertEqual(self.fake.slots[1].timer['playback'], 'stop')
        self.assertEqual(self.fake.slots[2].timer['playback'], 'start')
        self.assertFalse(any(p.startswith('/api/auxtimer/1/') for p in self.fake.calls))

    def test_shutdown_stops_owned_slot_even_if_orphan_poll_fails(self):
        self.path.write_text(json.dumps({'target': 'host', 'index': 1}))
        self.fake.slots[1].timer['playback'] = 'start'
        restarted = self.new()
        restarted.reset_session('s')
        restarted.ingest({'session': 's', 'sequence': 1, 'snapshot': snapshot()})
        restarted.process_outputs()
        self.fake.calls.clear()
        self.fake.fail = '/api/poll'
        restarted._recovery_due = 0
        restarted.close()
        self.assertEqual(self.fake.slots[1].timer['playback'], 'start')
        self.assertEqual(self.fake.slots[2].timer['playback'], 'stop')
        self.assertIn('/api/auxtimer/2/stop', self.fake.calls)
        self.assertEqual(json.loads(self.path.read_text())['indices'], [1])

    def test_ontime_loss_and_reconnect_resynchronizes_both_paused_slots(self):
        self.send(snapshot(state='paused'))
        self.bridge.ontime_unavailable()
        self.fake.fail = '/api/poll'
        self.bridge.process_outputs()
        self.assertEqual([self.statuses()[i]['output_status'] for i in (1, 2)], ['error', 'error'])
        self.fake.fail = None
        for slot in self.fake.slots.values():
            slot.timer.update(playback='stop', current=0, duration=0)
        self.seq += 1
        self.bridge.heartbeat({'session': 's', 'sequence': self.seq})
        self.bridge.process_outputs()
        self.assertEqual([self.fake.slots[i].timer['playback'] for i in (1, 2)], ['pause', 'pause'])
        self.assertEqual([self.statuses()[i]['output_status'] for i in (1, 2)], ['synced', 'synced'])

    def test_unused_legacy_display_settings_cannot_override_new_outputs(self):
        for legacy in ({'media_timer_source': 'off', 'aux_timer_index': 1},
                       {'media_timer_source': 'playlist', 'aux_timer_index': 'unused-invalid'}):
            cfg = config()
            cfg['timer'] = {**legacy, 'change_stage_timer_secondary_source': True}
            bridge = self.new(cfg, dry=True)
            bridge.reset_session('s')
            bridge.ingest({'session': 's', 'sequence': 1, 'snapshot': snapshot()})
            bridge.process_outputs()
            self.assertNotIn('output_error', bridge.status())
            self.assertFalse(bridge.status().get('last_ontime_action', {}).get('path', '').startswith('/api/message/timer?'))

    def test_inflight_snapshot_cannot_replace_shutdown_during_slot_cleanup(self):
        self.send()
        accepted = []
        def before(path):
            if path in ('/api/auxtimer/1/stop', '/api/auxtimer/2/stop'):
                try:
                    self.bridge.ingest({'session': 's', 'sequence': 100, 'snapshot': snapshot(snapshot_revision=99)})
                    accepted.append(True)
                except ValueError:
                    accepted.append(False)
        self.fake.before = before
        self.bridge.close()
        self.assertEqual(accepted, [False, False], 'Closing bridge must reject in-flight ingestion')
        self.assertEqual([self.fake.slots[i].timer['playback'] for i in (1, 2)], ['stop', 'stop'])
        self.assertFalse(self.path.exists())

    def test_new_item_during_pause_rebases_current_file_even_when_remaining_aligned(self):
        self.send()
        self.fake.slots[1].timer['current'] = 1000
        self.fake.calls.clear()
        self.send(snapshot(state='paused', current_item_id='new-short-clip', remaining_ms=1000,
                           duration_media_ms=1000, elapsed_media_ms=0, snapshot_revision=2))
        self.assertEqual(self.fake.slots[1].timer['duration'], 1000, 'New file must reset duration even during a state change')
        self.assertEqual(self.fake.slots[1].timer['playback'], 'pause')
        self.assertIn('/api/auxtimer/1/duration/1000', self.fake.calls)
