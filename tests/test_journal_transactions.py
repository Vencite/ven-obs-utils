import json
import os
import stat
import unittest
from pathlib import Path
from unittest.mock import patch

import test_multi_timers as fixtures


class JournalTransactionTests(unittest.TestCase):
    setUp = fixtures.MultiTimerTests.setUp
    new = fixtures.MultiTimerTests.new
    send = fixtures.MultiTimerTests.send
    def test_definite_replace_failure_does_not_survive_releasing_last_real_owner(self):
        replace = os.replace
        def fail_second(src, dst):
            if json.loads(Path(src).read_text()).get('indices') == [1, 2]:
                raise OSError('disk full before replace')
            replace(src, dst)
        with patch('media_bridge.os.replace', side_effect=fail_second):
            self.send()
        self.assertEqual(self.bridge._journal_slots, {1})
        self.assertEqual(json.loads(self.path.read_text())['indices'], [1])
        self.assertEqual(self.fake.slots[2].timer['playback'], 'stop')
        self.bridge.close()
        self.assertFalse(self.path.exists(), 'A definitely failed acquisition must not create an orphan')
        self.fake.calls.clear()
        restarted = self.new({'enabled': False})
        restarted.process_outputs()
        self.assertEqual(self.fake.calls, [])

    def test_file_fsync_failure_before_replace_is_definite(self):
        fsync = os.fsync
        calls = [0]
        def fail_third(fd):
            calls[0] += 1
            if calls[0] == 3:
                self.assertTrue(stat.S_ISREG(os.fstat(fd).st_mode))
                raise OSError('file fsync failed before replace')
            fsync(fd)
        with patch('media_bridge.os.fsync', side_effect=fail_third):
            self.send()
        self.assertEqual(self.bridge._journal_slots, {1})
        self.bridge.close()
        self.assertFalse(self.path.exists())

    def test_directory_fsync_failure_is_uncertain_and_preserved(self):
        fsync = os.fsync
        calls = [0]
        def fail_fourth(fd):
            calls[0] += 1
            if calls[0] == 4:
                self.assertTrue(stat.S_ISDIR(os.fstat(fd).st_mode))
                raise OSError('directory fsync after replace')
            fsync(fd)
        with patch('media_bridge.os.fsync', side_effect=fail_fourth):
            self.send()
        self.assertEqual(self.bridge._journal_slots, {1}, 'Uncertain durability is not confirmed')
        self.assertEqual(self.bridge.status()['journal_uncertain_indices'], [2])
        self.assertEqual(self.fake.slots[2].timer['playback'], 'stop')
        self.bridge.close()
        self.assertTrue(self.path.exists(), 'Unresolved intent must not be deleted with another slot')
        self.assertEqual(json.loads(self.path.read_text())['indices'], [2])
        self.fake.slots[2].timer['playback'] = 'start'  # another integration, no ownership proof
        self.fake.calls.clear()
        restarted = self.new({'enabled': False})
        restarted.process_outputs()
        self.assertEqual(self.fake.calls, ['/api/poll'])
        self.assertEqual(restarted.status()['recovery_timer_indices'], [2])

    def test_partial_release_failure_preserves_other_slot_and_retry(self):
        self.send()
        replace = os.replace
        def fail_release(src, dst):
            if json.loads(Path(src).read_text()).get('indices') == [2]:
                raise OSError('failed partial release')
            replace(src, dst)
        with patch('media_bridge.os.replace', side_effect=fail_release):
            self.bridge.close()
        self.assertEqual(self.fake.slots[2].timer['playback'], 'stop')
        self.assertEqual(json.loads(self.path.read_text())['indices'], [1])
        self.fake.calls.clear()
        restarted = self.new({'enabled': False})
        restarted.process_outputs()
        self.assertFalse(self.path.exists())
        self.assertEqual(self.fake.calls, ['/api/poll'])
