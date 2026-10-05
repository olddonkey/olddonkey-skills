"""Offline regression controls for authority review findings; no real remote."""
import ast
import contextlib
import errno
import io
import json
import os
import shutil
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
from loopauth import anchor, ceremony, recover, store, tools


def load_script(name):
    path = ROOT / 'scripts' / (name + '.py')
    module = types.ModuleType(name.replace('-', '_'))
    module.__file__ = str(path)
    sys.modules[module.__name__] = module
    code = path.read_text().rsplit('\nsys.exit(main(sys.argv[1:]))', 1)[0]
    exec(compile(code, str(path), 'exec'), module.__dict__)
    return module


verifier = load_script('loop-authority-verify')
writer = load_script('loop-authority')


class AuthorityReviewTests(unittest.TestCase):
    def test_intent_publication_has_one_link_at_first_directory_sync(self):
        with tempfile.TemporaryDirectory() as temp:
            target = str(Path(temp) / 'intent')
            observed = []
            class Crash(Exception):
                pass
            def crash_at_sync(_directory):
                observed.append(os.stat(target).st_nlink)
                raise Crash()
            with mock.patch.object(store, '_consume'), mock.patch.object(store, '_check_chain'), mock.patch.object(store, '_fsync_dir', side_effect=crash_at_sync):
                with self.assertRaises(Crash):
                    store._fs_create(object(), target, b'intent')
            self.assertEqual(observed, [1])
            self.assertEqual(Path(target).read_bytes(), b'intent')

    def test_create_never_replaces_an_existing_target(self):
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / 'intent'
            target.write_bytes(b'original')
            with mock.patch.object(store, '_consume'), mock.patch.object(store, '_check_chain'):
                with self.assertRaises(store.AuthorityError):
                    store._fs_create(object(), str(target), b'replacement')
            self.assertEqual(target.read_bytes(), b'original')

    def test_ls_remote_ignores_valid_tail_matched_branches(self):
        actual, stray = '1' * 40, '2' * 40
        for lines, expected in [
            (f'{actual}\t{tools.ANCHOR_REF}\n{stray}\trefs/heads/{tools.ANCHOR_REF}\n', actual),
            (f'{stray}\trefs/heads/{tools.ANCHOR_REF}\n', None),
        ]:
            with self.subTest(lines=lines), mock.patch.object(anchor, '_git', return_value=types.SimpleNamespace(returncode=0, stdout=lines.encode(), stderr=b'')):
                self.assertEqual(anchor.ls_remote('unused', 'file://unused'), expected)

    def test_remote_parse_anomalies_are_pending_not_chain_corruption(self):
        for text in ('garbled\n', 'x\t' + tools.ANCHOR_REF + '\n', ('1' * 40 + '\t' + tools.ANCHOR_REF + '\n') * 2):
            with self.subTest(text=text), mock.patch.object(anchor, '_git', return_value=types.SimpleNamespace(returncode=0, stdout=text.encode(), stderr=b'')):
                with self.assertRaises(anchor.Unreachable):
                    anchor.ls_remote('unused', 'file://unused')

    def test_missing_packed_fetch_ref_is_pending(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / 'packed-refs').write_text('# no fetched anchor\n')
            with self.assertRaises(anchor.Unreachable):
                anchor._packed_ref(directory)

    def test_slow_fetch_timeout_is_unreachable(self):
        runner = object.__new__(verifier.Runner)
        runner.temp = tempfile.gettempdir()
        actual_run = subprocess.run
        def short_timeout(*args, **kwargs):
            kwargs['timeout'] = 0.05
            return actual_run(*args, **kwargs)
        with mock.patch.object(verifier.Runner, 'env', return_value=dict(os.environ)), mock.patch.object(subprocess, 'run', side_effect=short_timeout):
            with self.assertRaises(verifier.Unreachable):
                runner.run([sys.executable, '-c', 'import time; time.sleep(10)'], git=True, form='fetch')

    def test_local_tool_timeouts_are_environment_errors(self):
        runner = object.__new__(verifier.Runner)
        runner.temp = tempfile.gettempdir()
        for form, git in [('init', True), ('cat-file', True), ('ssh-keygen', False)]:
            with self.subTest(form=form), mock.patch.object(verifier.Runner, 'env', return_value={}), mock.patch.object(subprocess, 'run', side_effect=subprocess.TimeoutExpired(form, 60)):
                with self.assertRaises(verifier.EnvError):
                    runner.run([form], git=git)

    def test_successful_fetch_without_valid_ref_is_pending(self):
        for leaf in (None, 'malformed\n'):
            with self.subTest(leaf=leaf), tempfile.TemporaryDirectory() as temp:
                runner = object.__new__(verifier.Runner)
                runner.repo = temp
                observed = types.SimpleNamespace(returncode=0, stdout=('1' * 40 + '\t' + tools.ANCHOR_REF + '\n').encode(), stderr=b'')
                fetched = types.SimpleNamespace(returncode=0, stdout=b'', stderr=b'')
                if leaf is not None:
                    path = Path(temp) / tools.READBACK_REF
                    path.parent.mkdir(parents=True)
                    path.write_text(leaf)
                with mock.patch.object(verifier.Runner, 'git_argv', side_effect=lambda form: [form]), mock.patch.object(verifier.Runner, 'run', side_effect=[observed, fetched]):
                    with self.assertRaises(verifier.Unreachable):
                        runner.fetch()
                with mock.patch.object(anchor, '_git', return_value=fetched):
                    with self.assertRaises(anchor.Unreachable):
                        anchor.fetch(temp, 'file://unused')

    def test_verifier_stray_only_ref_is_absent(self):
        runner = object.__new__(verifier.Runner)
        observed = types.SimpleNamespace(returncode=0, stdout=('1' * 40 + '\trefs/heads/' + tools.ANCHOR_REF + '\n').encode(), stderr=b'')
        with mock.patch.object(verifier.Runner, 'git_argv', side_effect=lambda form: [form]), mock.patch.object(verifier.Runner, 'run', return_value=observed) as run:
            self.assertIsNone(runner.fetch())
            run.assert_called_once()

    def test_scratch_push_ref_namespace_is_exclusive(self):
        commit = '1' * 40
        for refs, accepted in [(f'{commit} {tools.ANCHOR_REF}\n', True),
                               (f'{commit} {tools.ANCHOR_REF}\n{commit} refs/olddonkey-loop/extra\n', False)]:
            result = types.SimpleNamespace(returncode=0, stdout=refs.encode())
            with self.subTest(refs=refs), mock.patch.object(anchor, '_git', return_value=result):
                if accepted:
                    anchor.prepare_push('scratch', commit)
                else:
                    with self.assertRaises(anchor.AnchorError):
                        anchor.prepare_push('scratch', commit)

    def test_intent_crash_cuts_select_each_intent_target(self):
        for leaf in ('genesis.intent', 'regenesis.intent', 'intent', 'quarantine', 'segment-000001.olf'):
            with self.subTest(leaf=leaf), tempfile.TemporaryDirectory() as temp:
                points = []
                with mock.patch.object(store, '_consume'), mock.patch.object(store, '_check_chain'), mock.patch.object(store, 'crash', side_effect=points.append):
                    store._fs_create(object(), str(Path(temp) / leaf), b'test')
                expected = ['fs-create-after-temp-fsync', 'fs-create-after-rename']
                kind = 'marker' if leaf == 'quarantine' else 'intent'
                if leaf != 'segment-000001.olf':
                    expected = [expected[0], f'fs-create-{kind}-after-temp-fsync', expected[1], f'fs-create-{kind}-after-rename']
                self.assertEqual(points, expected)

    def test_fullfsync_unsupported_remains_a_hard_environment_failure(self):
        for code in (errno.ENOTSUP, errno.ENOTTY, errno.EINVAL):
            with self.subTest(errno=code), mock.patch.object(store.sys, 'platform', 'darwin'), mock.patch.object(store.fcntl, 'fcntl', side_effect=OSError(code, 'unsupported')), mock.patch.object(store.os, 'fsync') as plain:
                with self.assertRaises(OSError):
                    store._durable_fsync(123)
                plain.assert_not_called()

    def test_surrogate_value_and_key_are_canonical_refusals(self):
        for value in ({'payload': '\ud800', 'sig': 'x'}, {'\ud800': 'x'}):
            with self.subTest(value=repr(value)):
                with self.assertRaises(verifier.Bad):
                    verifier.load_canonical(__import__('json').dumps(value).encode(), 'test')

    def test_replay_parent_fetch_failure_is_pending(self):
        plan = types.SimpleNamespace(params={'intent': {'anchor_json': '{}', 'expected_parent': '1' * 40, 'seq': 2}, 'remote_seq': 1}, view=types.SimpleNamespace(L=1))
        with mock.patch.object(recover.registry, 'validate'), mock.patch.object(anchor, 'build_objects', side_effect=anchor.AnchorError('anchor-parent-pending', 'fetch failed')):
            with self.assertRaises(store.AuthorityError) as raised:
                recover._replay(plan, lambda: 'scratch')
        self.assertEqual(raised.exception.exit_code, store.EXIT_PENDING)

    def test_push_timeout_is_pending(self):
        bound = {'expected_parent': '1' * 40, 'anchor_commit': '2' * 40, 'ref': tools.ANCHOR_REF}
        token = types.SimpleNamespace(kind='child', flags={'frame'}, stages={'anchor': bound})
        with mock.patch.object(store, '_require', return_value=token), mock.patch.object(store, '_root_token', return_value=token), mock.patch.object(tools, 'pinned_remote', return_value=types.SimpleNamespace(url='file://fake')), mock.patch.object(anchor, 'ls_remote', return_value=bound['expected_parent']), mock.patch.object(anchor, 'prepare_push'), mock.patch.object(store, '_run_sink', side_effect=tools.ToolError('timeout', 'push timed out')):
            with self.assertRaises(store.AuthorityError) as raised:
                store.push_anchor(token, scratch='scratch', commit=bound['anchor_commit'], ref=tools.ANCHOR_REF)
        self.assertEqual(raised.exception.exit_code, store.EXIT_PENDING)

    def test_real_store_writer_verifier_agreement_for_round3(self):
        # As in registry-selftest: exercise the real ceremony core with a
        # fixed test principal/challenge. The pty entry remains covered by
        # authority-selftest's agreement corpus, without stubbing its reads.
        with tempfile.TemporaryDirectory(dir='/tmp') as temp:
            home = str(Path(temp).resolve() / 'home')
            Path(home).mkdir()
            remote = str(Path(temp).resolve() / 'remote.git')
            principal = {'kind': 'operator-tty', 'tty': '/dev/ttys000',
                         'start_token': {'boot_id': 'TESTBOOT-0000', 'pid': 1, 'start_time': 1}}
            with mock.patch.dict(os.environ, {'HOME': home, 'LOOP_AUTHORITY_TEST': '1'}), mock.patch.object(ceremony, 'challenge'):
                tools.cleanup()
                tools._PINNED.clear()
                def git(*args):
                    return subprocess.run([tools.resolve('git'), '--git-dir', remote, *args],
                                          capture_output=True, check=True, env=tools.git_env()).stdout
                try:
                    subprocess.run([tools.resolve('git'), 'init', '--bare', '-q', remote], check=True, env=tools.git_env())
                    with store.WriterLock():
                        ceremony.genesis(principal, 'file://' + remote)
                    original = git('rev-parse', tools.ANCHOR_REF).strip().decode()
                    stray = 'refs/heads/' + tools.ANCHOR_REF
                    git('update-ref', stray, original)
                    for operation in (lambda: ceremony.rotate(principal), lambda: ceremony.revoke(principal, 1)):
                        with store.WriterLock():
                            operation()
                        pool = recover.Scratch()
                        try:
                            plan = recover.observe(pool)
                            self.assertEqual(plan.state, 'committed')
                        finally:
                            pool.close()
                        independent = subprocess.run(['bash', str(ROOT / 'scripts/loop-authority-verify')], capture_output=True, env=dict(os.environ))
                        self.assertEqual(independent.returncode, 0, independent.stderr)
                        self.assertEqual(json.loads(independent.stdout)['state'], 'committed')
                        self.assertEqual(git('rev-parse', stray).strip().decode(), original)
                    bins = Path(temp) / 'bins'
                    bins.mkdir()
                    def check_cli(state, code, fixture_env, scripts=ROOT / 'scripts'):
                        for name, args in [('loop-authority', ['verify']), ('loop-authority-verify', [])]:
                            result = subprocess.run(['bash', str(scripts / name), *args], capture_output=True,
                                                    env=dict(os.environ, **fixture_env))
                            self.assertEqual(result.returncode, code, (name, result.stderr))
                            if state is not None:
                                self.assertEqual(json.loads(result.stdout)['state'], state)
                            else:
                                self.assertIn(b'timed out', result.stderr)
                    real_git = tools.resolve('git')
                    for malformed in (False, True):
                        wrapper = bins / 'git'
                        code = '#!' + sys.executable + "\nimport os, sys\na=sys.argv[1:]\nif 'fetch' in a:\n"
                        if malformed:
                            code += "    path=os.path.join(a[a.index('-C')+1], 'refs/readback/anchor')\n    os.makedirs(os.path.dirname(path), exist_ok=True)\n    open(path, 'w').write('malformed\\n')\n"
                        code += '    sys.exit(0)\nos.execv(' + repr(real_git) + ', [' + repr(real_git) + '] + a)\n'
                        wrapper.write_text(code)
                        wrapper.chmod(0o700)
                        check_cli('pending', 5, {'LOOP_AUTHORITY_TEST_BIN_DIR': str(bins)})
                    (bins / 'git').unlink()
                    package = Path(temp) / 'package'
                    shutil.copytree(ROOT / 'lib', package / 'lib')
                    shutil.copytree(ROOT / 'scripts', package / 'scripts')
                    tool_path = package / 'lib/loopauth/tools.py'
                    tool_path.write_text(tool_path.read_text().replace('LOCAL_TIMEOUT = 60', 'LOCAL_TIMEOUT = 0.5'))
                    verify_path = package / 'scripts/loop-authority-verify.py'
                    verify_path.write_text(verify_path.read_text().replace('else 60,', 'else 0.5,'))
                    for form, binary in [('init', 'git'), ('cat-file', 'git'), ('verify', 'ssh-keygen')]:
                        wrapper = bins / binary
                        actual = tools.resolve(binary)
                        wrapper.write_text('#!' + sys.executable + '\nimport os, sys, time\na=sys.argv[1:]\nif ' + repr(form) + ' in a: time.sleep(2)\nos.execv(' + repr(actual) + ', [' + repr(actual) + '] + a)\n')
                        wrapper.chmod(0o700)
                        check_cli(None, 9, {'LOOP_AUTHORITY_TEST_BIN_DIR': str(bins)}, package / 'scripts')
                        wrapper.unlink()
                    git('update-ref', stray, git('rev-parse', tools.ANCHOR_REF).strip().decode())
                    git('update-ref', '-d', tools.ANCHOR_REF)
                    pool = recover.Scratch()
                    try:
                        plan = recover.observe(pool)
                        self.assertEqual(plan.state, 'quarantined')
                        self.assertEqual(plan.params['rule'], 'anchor-absent')
                    finally:
                        pool.close()
                    independent = subprocess.run(['bash', str(ROOT / 'scripts/loop-authority-verify')], capture_output=True, env=dict(os.environ))
                    self.assertEqual(independent.returncode, 6, independent.stderr)
                    self.assertEqual(json.loads(independent.stdout)['state'], 'quarantined')
                    tools.cleanup()
                    tools._PINNED.clear()
                    fresh_home = Path(temp).resolve() / 'fresh-home'
                    fresh_home.mkdir()
                    with mock.patch.dict(os.environ, {'HOME': str(fresh_home)}):
                        class AtFrame(Exception):
                            pass
                        def crash(point):
                            if point == 'after-frame-fsync':
                                raise AtFrame()
                        with mock.patch.object(store, 'crash', side_effect=crash):
                            with self.assertRaises(AtFrame), store.WriterLock():
                                ceremony.genesis(principal, 'file://' + remote)
                        check_cli('genesis-pending', 5, {})
                        with store.WriterLock():
                            recover.recover()
                        check_cli('committed', 0, {})
                        tools.cleanup()
                        tools._PINNED.clear()
                finally:
                    tools.cleanup()
                    tools._PINNED.clear()

    def test_main_reports_last_resort_failures_without_tracebacks(self):
        modules = writer.load_loopauth()
        for error, expected in ((OSError("synthetic ENOSPC"), store.EXIT_ENV),
                                (anchor.AnchorError("anchor-object", "synthetic bad object"), store.EXIT_REFUSED),
                                (anchor.Unreachable("synthetic remote failure"), store.EXIT_PENDING)):
            output = io.StringIO()
            with self.subTest(error=type(error).__name__), mock.patch.object(writer, 'load_loopauth', return_value=modules), mock.patch.object(tools, 'establish_scratch', side_effect=error), mock.patch.object(tools, 'cleanup'), contextlib.redirect_stderr(output):
                self.assertEqual(writer.main(['status']), expected)
            self.assertEqual(len(output.getvalue().splitlines()), 1)
            self.assertNotIn('Traceback', output.getvalue())

    def test_empty_store_does_not_verify(self):
        self.assertEqual(verifier.exit_code({'state': 'none'}), store.EXIT_INVALID)
        plan = types.SimpleNamespace(state='none', row=None)
        self.assertEqual(writer.exit_for(store, recover, plan, verify=True), store.EXIT_INVALID)

    def test_durable_sync_uses_fullfsync_on_darwin(self):
        self.assertTrue(hasattr(store, '_durable_fsync'))
        with mock.patch.object(store.fcntl, 'F_FULLFSYNC', 51, create=True), mock.patch.object(store.sys, 'platform', 'darwin'), mock.patch.object(store.fcntl, 'fcntl') as full, mock.patch.object(store.os, 'fsync') as plain:
            store._durable_fsync(123)
            full.assert_called_once_with(123, store.fcntl.F_FULLFSYNC)
            plain.assert_not_called()
        with mock.patch.object(store.sys, 'platform', 'linux'), mock.patch.object(store.fcntl, 'fcntl') as full, mock.patch.object(store.os, 'fsync') as plain:
            store._durable_fsync(123)
            plain.assert_called_once_with(123)
            full.assert_not_called()

    def test_every_fsync_primitive_routes_through_durable_helper(self):
        tree = ast.parse((ROOT / 'lib/loopauth/store.py').read_text())
        functions = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
        for name in ('_fsync_dir', '_fs_create', '_fs_replace', '_fs_append', '_fs_truncate', '_fs_link_published'):
            calls = [n.func for n in ast.walk(functions[name]) if isinstance(n, ast.Call)]
            with self.subTest(primitive=name):
                self.assertTrue(any(isinstance(n, ast.Name) and n.id == '_durable_fsync' for n in calls))
                self.assertFalse(any(isinstance(n, ast.Attribute) and n.attr == 'fsync' for n in calls))
        for name in ('_fs_mkdir', '_fs_unlink', '_fs_rename_dir', '_fs_read_only_tree', '_fs_unlink_temp'):
            calls = [n.func for n in ast.walk(functions[name]) if isinstance(n, ast.Call)]
            with self.subTest(primitive=name):
                self.assertTrue(any(isinstance(n, ast.Name) and n.id == '_fsync_dir' for n in calls))


if __name__ == '__main__':
    unittest.main()
