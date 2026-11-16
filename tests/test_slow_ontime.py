"""Controlled latency/timeout tests; elapsed seconds are fake, gates do not sleep."""
import json
import threading
import unittest
from unittest.mock import patch

import test_multi_timers as fixtures


class SlowOntimeTests(unittest.TestCase):
    setUp = fixtures.MultiTimerTests.setUp
    new = fixtures.MultiTimerTests.new
    send = fixtures.MultiTimerTests.send
    statuses = fixtures.MultiTimerTests.statuses

    def test_several_two_second_commands_keep_ipc_live_and_cycle_finite(self):
        clock = [100.0]
        calls = [0]
        original = self.bridge._get
        def slow(path):
            calls[0] += 1
            clock[0] += 2
            self.seq += 1
            self.bridge.heartbeat({'session': 's', 'sequence': self.seq})
            return original(path)
        self.bridge._get = slow
        with patch('media_bridge.time.monotonic', side_effect=lambda: clock[0]):
            self.send(fixtures.snapshot(state='paused'))
            self.assertTrue(self.bridge.status()['available'])
            self.assertEqual([self.statuses()[i]['output_status'] for i in (1, 2)], ['synced', 'synced'])
            self.assertEqual(clock[0] - 100, calls[0] * 2)
            self.assertLessEqual(clock[0] - 100, calls[0] * 3)
            self.assertEqual(self.fake.calls.count('/api/poll'), 1)

    def test_new_revision_during_slow_http_does_not_dispatch_old_second_slot(self):
        entered, release = threading.Event(), threading.Event()
        def gate(path):
            if path == '/api/auxtimer/1/direction/count-down':
                entered.set()
                if not release.wait(2):
                    raise TimeoutError('controlled deadline')
        self.fake.before = gate
        self.seq = 1
        self.bridge.ingest({'session': 's', 'sequence': 1, 'snapshot': fixtures.snapshot()})
        worker = threading.Thread(target=self.bridge.process_outputs)
        worker.start()
        try:
            self.assertTrue(entered.wait(1))
            live = self.bridge.status()
            self.assertEqual(live['current_item_id'], 'entry-1')
            self.bridge.ingest({'session': 's', 'sequence': 2, 'snapshot': fixtures.snapshot(
                snapshot_revision=2, remaining_ms=1200, playlist_remaining_ms=2400)})
            self.assertEqual(self.bridge.status()['remaining_ms'], 1200)
        finally:
            release.set()
            worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertNotIn('/api/auxtimer/1/duration/3000', self.fake.calls)
        self.assertFalse(any(p.startswith('/api/auxtimer/2/') for p in self.fake.calls))
        self.fake.before = None
        self.bridge.process_outputs()
        self.assertEqual([self.fake.slots[i].timer['current'] for i in (1, 2)], [1200, 2400])

    def test_new_session_during_slow_poll_keeps_status_nonblocking(self):
        entered, release = threading.Event(), threading.Event()
        def gate(path):
            if path == '/api/poll':
                entered.set()
                if not release.wait(2):
                    raise TimeoutError('controlled deadline')
        self.fake.before = gate
        self.bridge.ingest({'session': 's', 'sequence': 1, 'snapshot': fixtures.snapshot(state='paused')})
        worker = threading.Thread(target=self.bridge.process_outputs)
        worker.start()
        try:
            self.assertTrue(entered.wait(1))
            self.bridge.reset_session('reconnect', 10)
            self.assertFalse(self.bridge.status()['available'])
        finally:
            release.set()
            worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(self.fake.calls, ['/api/poll'])

    def test_close_during_blocked_start_waits_then_cleans_owned_timer(self):
        entered, release = threading.Event(), threading.Event()
        def gate(path):
            if path == '/api/auxtimer/1/start':
                entered.set()
                if not release.wait(2):
                    raise TimeoutError('controlled deadline')
        self.fake.before = gate
        self.bridge.ingest({'session': 's', 'sequence': 1, 'snapshot': fixtures.snapshot()})
        self.bridge.start()
        closer = threading.Thread(target=self.bridge.close)
        try:
            self.assertTrue(entered.wait(1))
            closer.start()
            self.assertTrue(self.bridge._closed.wait(1))
            self.assertFalse(self.bridge.status()['available'])
            with self.assertRaises(ValueError):
                self.bridge.ingest({'session': 's', 'sequence': 2, 'snapshot': fixtures.snapshot()})
        finally:
            release.set()
            if closer.ident:
                closer.join(3)
        self.assertFalse(closer.is_alive())
        self.assertEqual([self.fake.slots[i].timer['playback'] for i in (1, 2)], ['stop', 'stop'])
        self.assertFalse(self.path.exists())

    def test_production_transport_passes_deadline_and_timeout_does_not_block_aux2(self):
        import os
        from urllib.request import Request, urlopen
        import ontime_break_sync as helper
        timeouts = []
        healthy = threading.Event()
        fake = self.fake
        class Response:
            def __init__(self, body): self.body = body
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read(self, *_): return self.body
        def transport(request, timeout):
            timeouts.append(timeout)
            path = request.full_url.removeprefix('http://fake')
            if path == '/api/auxtimer/1/start':
                raise TimeoutError('simulated three-second deadline')
            result = fake(path)
            if path == '/api/auxtimer/2/start': healthy.set()
            return Response(json.dumps(result).encode())
        with patch.dict(os.environ, {'VEN_MEDIA_IPC_TOKEN': 'slow-test'}), patch.object(helper, 'urlopen', side_effect=transport):
            server = helper.create_local_server(helper.Config(ontime_base_url='http://fake', dry_run=False,
                request_timeout_seconds=3, media_bridge=fixtures.config(), ownership_path=self.path), port=0)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                url = 'http://127.0.0.1:%d' % server.server_address[1]
                for path, body in [('/media/_session', {'session':'s', 'epoch':1}),
                                   ('/media/_snapshot', {'session':'s', 'sequence':1, 'snapshot':fixtures.snapshot()})]:
                    request = Request(url + path, data=json.dumps(body).encode(), headers={'Authorization':'Bearer slow-test'})
                    with urlopen(request, timeout=2) as response:
                        self.assertEqual(response.status, 200)
                self.assertTrue(healthy.wait(2), 'Aux2 must progress after Aux1 timeout')
                self.assertTrue(timeouts and all(t == 3 for t in timeouts))
                with urlopen(Request(url + '/media/_status', headers={'Authorization':'Bearer slow-test'}), timeout=2) as response:
                    states = {r['aux_timer_index']:r for r in json.load(response)['auxiliary_timers']}
                self.assertEqual(states[1]['output_status'], 'error')
                self.assertEqual(states[2]['output_status'], 'synced')
            finally:
                server.shutdown()
                server.server_close()
                worker.join(2)
