"""Offline regressions for lock-free reference observation and CLI byte I/O."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'lib'))
from loopauth import refs, recover, store


def plan(state='committed', *, remote_read=True):
    return types.SimpleNamespace(state=state, remote_read=remote_read, summary=lambda: {
        'state': state, 'authorizing_state': state == 'committed',
        'anchor_class': 'test', 'test_only': True, 'current_authorization': False,
    })


class ObservationTests(unittest.TestCase):
    def test_change_during_classification_is_retried(self):
        with mock.patch.object(store, 'snapshot_digest', side_effect=['old', 'new', 'new', 'new']), mock.patch.object(recover, 'classify', side_effect=[plan('quarantined'), plan()]) as classify:
            self.assertEqual(refs.observe_store()['state'], 'current')
            self.assertEqual(classify.call_count, 2)

    def test_disappearing_intent_during_classification_is_retried(self):
        with mock.patch.object(store, 'snapshot_digest', side_effect=['old', 'new', 'new', 'new']), mock.patch.object(recover, 'classify', side_effect=[FileNotFoundError('intent disappeared'), plan()]) as classify:
            self.assertEqual(refs.observe_store()['state'], 'current')
            self.assertEqual(classify.call_count, 2)

    def test_failed_remote_read_is_retried_to_current(self):
        with mock.patch.object(store, 'snapshot_digest', return_value='stable'), mock.patch.object(recover, 'classify', side_effect=[plan('pending', remote_read=False), plan()]) as classify:
            self.assertEqual(refs.observe_store()['state'], 'current')
            self.assertEqual(classify.call_count, 2)

    def test_failed_remote_read_is_retried_to_pending(self):
        with mock.patch.object(store, 'snapshot_digest', return_value='stable'), mock.patch.object(recover, 'classify', side_effect=[plan('pending', remote_read=False), plan('pending')]) as classify:
            self.assertEqual(refs.observe_store()['reason'], 'pending')
            self.assertEqual(classify.call_count, 2)

    def test_persistent_remote_failure_is_bounded(self):
        with mock.patch.object(store, 'snapshot_digest', return_value='stable'), mock.patch.object(recover, 'classify', return_value=plan('pending', remote_read=False)) as classify:
            self.assertEqual(refs.observe_store()['reason'], 'remote-unreachable')
            self.assertEqual(classify.call_count, 2)

    def test_layout_error_with_changed_snapshot_is_retried(self):
        error = store.AuthorityError('layout', 'file missing')
        with mock.patch.object(store, 'snapshot_digest', side_effect=['old', 'new', 'new', 'new']), mock.patch.object(recover, 'classify', side_effect=[error, plan()]) as classify:
            self.assertEqual(refs.observe_store()['state'], 'current')
            self.assertEqual(classify.call_count, 2)

    def test_identical_snapshot_reraises_classification_errors(self):
        for error in (store.AuthorityError('layout', 'file missing'), RuntimeError('classifier failed'), FileNotFoundError('intent missing')):
            with self.subTest(error=type(error).__name__), mock.patch.object(store, 'snapshot_digest', return_value='stable') as digest, mock.patch.object(recover, 'classify', side_effect=error) as classify:
                with self.assertRaises(type(error)) as caught:
                    refs.observe_store()
                self.assertIs(caught.exception, error)
                self.assertEqual(digest.call_count, 2)
                self.assertEqual(classify.call_count, 1)

    def test_missing_after_digest_is_retried(self):
        with mock.patch.object(store, 'snapshot_digest', side_effect=['old', FileNotFoundError('store archived'), 'new', 'new']), mock.patch.object(recover, 'classify', side_effect=[store.AuthorityError('layout', 'file missing'), plan()]) as classify:
            self.assertEqual(refs.observe_store()['state'], 'current')
            self.assertEqual(classify.call_count, 2)

    def test_continuous_change_is_bounded_and_explicit(self):
        with mock.patch.object(store, 'snapshot_digest', side_effect=[str(n) for n in range(6)]), mock.patch.object(recover, 'classify', return_value=plan()) as classify:
            result = refs.observe_store()
            self.assertEqual(result['state'], 'unavailable')
            self.assertEqual(result['reason'], 'changing')
            self.assertFalse(result['current_authorization'])
            self.assertEqual(classify.call_count, 3)

    def test_repeated_io_failure_is_bounded(self):
        error = PermissionError('Permission denied')
        with mock.patch.object(store, 'snapshot_digest', return_value='stable') as digest, mock.patch.object(recover, 'classify', side_effect=error) as classify:
            with self.assertRaises(PermissionError) as caught:
                refs.observe_store()
            self.assertIs(caught.exception, error)
            self.assertEqual(digest.call_count, 2)
            self.assertEqual(classify.call_count, 1)

    def test_unreadable_snapshots_reraise_last_error_within_bound(self):
        errors = [OSError('unreadable tree'), PermissionError('Permission denied'), FileNotFoundError('store missing')]
        with mock.patch.object(store, 'snapshot_digest', side_effect=errors) as digest, mock.patch.object(recover, 'classify') as classify:
            with self.assertRaises(FileNotFoundError) as caught:
                refs.observe_store()
            self.assertIs(caught.exception, errors[-1])
            self.assertEqual(digest.call_count, 3)
            classify.assert_not_called()

    def test_no_after_digest_reraises_last_error(self):
        error = PermissionError('cannot read after classification')
        with mock.patch.object(store, 'snapshot_digest', side_effect=['old', error] * 3) as digest, mock.patch.object(recover, 'classify', side_effect=store.AuthorityError('layout', 'file missing')) as classify:
            with self.assertRaises(PermissionError) as caught:
                refs.observe_store()
            self.assertIs(caught.exception, error)
            self.assertEqual(digest.call_count, 6)
            self.assertEqual(classify.call_count, 3)

    def test_changed_snapshot_then_unreadable_snapshots_reports_changing(self):
        with mock.patch.object(store, 'snapshot_digest', side_effect=['old', 'new', OSError('unreadable'), OSError('unreadable')]), mock.patch.object(recover, 'classify', side_effect=RuntimeError('changed during read')) as classify:
            result = refs.observe_store()
            self.assertEqual(result['reason'], 'changing')
            self.assertFalse(result['current_authorization'])
            self.assertEqual(classify.call_count, 1)


class CommandTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir='/tmp')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.ws = self.root / 'café-项目'
        self.ws.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), LC_ALL='C')
        for key in list(self.env):
            if key.startswith('LOOP_') or key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_CONFIG_COUNT'):
                self.env.pop(key)
        started = subprocess.run(['bash', str(ROOT / 'scripts/loop-journal'), 'begin-run', '--workspace', str(self.ws)], env=self.env, capture_output=True, timeout=20)
        self.assertEqual(started.returncode, 0, started.stderr)
        self.run_id = next(line[4:] for line in started.stdout.decode().splitlines() if line.startswith('run='))
        key = hashlib.sha256(str(self.ws).encode()).hexdigest()
        self.segment = self.home / '.config/olddonkey-loop/journal' / key / 'runs' / (self.run_id + '.jsonl')
        self.args = ['refs', '--workspace', str(self.ws), '--run', self.run_id]

    def invoke(self, args=None, timeout=20):
        return subprocess.run(['bash', str(ROOT / 'scripts/loop-authority'), *(args or self.args)], env=self.env, capture_output=True, timeout=timeout)

    def test_fifo_is_rejected_without_waiting_for_a_writer(self):
        self.segment.unlink()
        os.mkfifo(self.segment, 0o600)
        try:
            result = self.invoke(timeout=20)
        except subprocess.TimeoutExpired:
            self.fail('refs blocked waiting for a FIFO writer')
        self.assertEqual(result.returncode, 12, result.stderr)
        self.assertIn(b'journal-unsafe', result.stderr)

    def test_non_utf8_stdout_still_emits_canonical_utf8(self):
        script = str(ROOT / 'scripts/loop-authority.py')
        launcher = 'import runpy,sys; sys.stdout.reconfigure(encoding="latin-1"); sys.argv=sys.argv[1:]; runpy.run_path(sys.argv[0], run_name="__main__")'
        result = subprocess.run([sys.executable, '-I', '-B', '-c', launcher, script, *self.args], env=self.env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout.decode('utf-8'))
        self.assertEqual(value['workspace'], str(self.ws))
        expected = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode() + b'\n'
        self.assertEqual(result.stdout, expected)

    def test_closed_stdout_is_a_coded_environment_error(self):
        result = subprocess.run(['bash', '-c', 'exec "$@" >&-', '--', 'bash', str(ROOT / 'scripts/loop-authority'), *self.args], env=self.env, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 9, result.stderr)
        self.assertEqual(result.stdout, b'')
        self.assertIn(b'error: output: refs requires an open stdout', result.stderr)
        self.assertNotIn(b'Traceback', result.stderr)
        self.assertFalse((self.home / '.cache').exists())

    def test_report_binds_the_fold_to_the_requested_run(self):
        lines = [json.loads(line) for line in self.segment.read_text().splitlines()]
        lines[0]['run'] = '20990101T000000Z-abcdef'
        self.segment.write_text(''.join(json.dumps(line) + '\n' for line in lines))
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report['run'], self.run_id)
        self.assertEqual([item['code'] for item in report['journal']['rejected']], ['run-mismatch'])

    def test_invalid_journal_creates_no_scratch_cache(self):
        self.assertFalse((self.home / '.cache').exists())
        result = self.invoke(['refs', '--workspace', str(self.ws), '--run', 'not-a-run'])
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse((self.home / '.cache').exists())


if __name__ == '__main__':
    unittest.main()
