"""Offline authority review regressions, including real file:// Git remotes.

Expected full run: Ran 33 tests, OK. Subtests cover each namespace/crash variant.
"""
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


PRINCIPAL = {'kind': 'operator-tty', 'tty': '/dev/ttys000',
             'start_token': {'boot_id': 'TESTBOOT-0000', 'pid': 1, 'start_time': 1}}


class RealAuthority:
    """Real store/keys/transport; only the operator challenge is stubbed.

    Git wrappers execute real Git, then perturb the remote or readback. No
    transport result is mocked. All writable fixtures are under /tmp.
    """
    def __enter__(self):
        self.stack = contextlib.ExitStack()
        self.base = Path(self.stack.enter_context(tempfile.TemporaryDirectory(dir='/tmp'))).resolve()
        self.home = self.base / 'home'
        self.home.mkdir()
        self.remote = self.base / 'remote.git'
        self.url = 'file://' + str(self.remote)
        self.stack.enter_context(mock.patch.dict(os.environ, {'HOME': str(self.home),
                                 'LOOP_AUTHORITY_TEST': '1', 'PYTHONDONTWRITEBYTECODE': '1'}))
        os.environ.pop('LOOP_AUTHORITY_TEST_BIN_DIR', None)
        os.environ.pop('LOOP_AUTHORITY_CRASH_AT', None)
        self.stack.enter_context(mock.patch.object(ceremony, 'challenge'))
        self.reset()
        self.gitbin = tools.resolve('git')
        self.git_at(self.remote, 'init', '--bare', '-q', str(self.remote))
        self.perform('genesis', self.url)
        self.auth = self.home / '.config/olddonkey-loop/authority'
        self.store = self.auth / 'stores' / json.loads((self.auth / 'active').read_bytes())['store_id']
        return self

    def __exit__(self, *exc):
        self.reset()
        return self.stack.__exit__(*exc)

    def reset(self):
        tools.cleanup()
        tools._PINNED.clear()
        tools._RESOLVED.clear()
        anchor._READ.clear()

    def git_at(self, repo, *args, stdin=None, check=True):
        return subprocess.run([self.gitbin, '--git-dir', str(repo), *args], input=stdin,
                              capture_output=True, check=check, env=dict(tools.git_env(),
                              GIT_AUTHOR_NAME='fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                              GIT_COMMITTER_NAME='fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid'))

    def git(self, *args, **kwargs):
        return self.git_at(self.remote, *args, **kwargs).stdout.decode().strip()

    def tip(self):
        return self.git('rev-parse', tools.ANCHOR_REF)

    def perform(self, command, *args):
        self.reset()
        try:
            with store.WriterLock():
                return getattr(ceremony, command)(PRINCIPAL, *args)
        finally:
            self.reset()

    def scratch(self):
        tools.pin_remote(tools.parse_remote(self.url, allow_test=True))
        return tools.new_scratch_repo()

    def wrapper(self, body):
        bins = self.base / 'bins'
        bins.mkdir(exist_ok=True)
        wrapper = bins / 'git'
        wrapper.write_text('#!' + sys.executable + '\nimport os, subprocess, sys, time\n'
                           + 'REAL = ' + repr(self.gitbin) + '\nREMOTE = ' + repr(str(self.remote))
                           + '\na = sys.argv[1:]\n' + body
                           + '\nos.execv(REAL, [REAL] + a)\n')
        wrapper.chmod(0o700)
        return {'LOOP_AUTHORITY_TEST_BIN_DIR': str(bins)}

    def agree(self, test, state, code, env=None, scripts=None):
        for name, args in [('loop-authority', ['verify']), ('loop-authority-verify', [])]:
            result = subprocess.run(['bash', str((scripts or ROOT / 'scripts') / name), *args],
                                    capture_output=True, env=dict(os.environ, **(env or {})))
            test.assertEqual(result.returncode, code, (name, result.stdout, result.stderr))
            value = json.loads(result.stdout)
            test.assertEqual(value['state'], state, (name, value))
            test.assertNotIn(b'Traceback', result.stderr)

    def packed(self, repo, additions):
        self.git_at(repo, 'pack-refs', '--all')
        path = Path(repo) / 'packed-refs'
        lines = [line for line in path.read_text().splitlines() if line and not line.startswith(('#', '^'))]
        lines += additions
        lines.sort(key=lambda line: line.split(' ', 1)[1].encode())
        path.write_text('# pack-refs with: peeled fully-peeled sorted \n' + '\n'.join(lines) + '\n')

    def other_commit(self, repo):
        blob = self.git_at(repo, 'hash-object', '-w', '--stdin', stdin=b'unrelated\n').stdout.strip().decode()
        tree = self.git_at(repo, 'mktree', stdin=f'100644 blob {blob}\tother\n'.encode()).stdout.strip().decode()
        return self.git_at(repo, 'commit-tree', tree, '-m', 'unrelated').stdout.strip().decode()

    @staticmethod
    def snapshot(path):
        return {str(p.relative_to(path)): (p.stat().st_mode, p.read_bytes())
                for p in path.rglob('*') if p.is_file()}


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
        for leaf in ('missing', 'malformed', 'directory', 'packed-directory'):
            with self.subTest(leaf=leaf), RealAuthority() as lab:
                # Let real Git fetch successfully before damaging its result.
                damage = {
                    'missing': '',
                    'malformed': "    open(path, 'w').write('malformed\\n')\n",
                    'directory': '    os.mkdir(path)\n',
                    'packed-directory': "    os.mkdir(os.path.join(root, 'packed-refs'))\n",
                }[leaf]
                env = lab.wrapper("if 'fetch' in a:\n"
                    "    done = subprocess.run([REAL] + a)\n"
                    "    if done.returncode: sys.exit(done.returncode)\n"
                    "    root = a[a.index('-C') + 1]\n"
                    "    path = os.path.join(root, 'refs/readback/anchor')\n"
                    "    os.unlink(path)\n" + damage + "    sys.exit(0)\n")
                lab.agree(self, 'pending', 5, env)

    def test_verifier_stray_only_ref_is_absent(self):
        with RealAuthority() as lab:
            lab.git('update-ref', 'refs/heads/' + tools.ANCHOR_REF, lab.tip())
            lab.git('update-ref', '-d', tools.ANCHOR_REF)
            lab.agree(self, 'quarantined', 6)
            # Both fetch APIs must skip fetch even though Git would tail-match.
            trace = lab.base / 'fetch-trace'
            env = lab.wrapper("if 'fetch' in a:\n    open(" + repr(str(trace))
                              + ", 'a').write('fetch\\n')\n")
            with mock.patch.dict(os.environ, env):
                lab.reset()
                self.assertIsNone(anchor.fetch(lab.scratch(), lab.url))
                runner = verifier.Runner()
                runner.remote = verifier.parse_remote(lab.url)
                runner.make_temp()
                try:
                    runner.init_repo()
                    self.assertIsNone(runner.fetch())
                finally:
                    runner.cleanup()
            self.assertFalse(trace.exists())

    def test_scratch_push_ref_namespace_is_exclusive(self):
        for kind in ('loose', 'packed', 'symbolic', 'dangling-symbolic', 'case-variant', 'symbolic-anchor'):
            with self.subTest(kind=kind), RealAuthority() as lab:
                tip = lab.tip()
                scratch = lab.scratch()
                self.assertEqual(anchor.fetch(scratch, lab.url), tip)
                anchor.prepare_push(scratch, tip)
                extra = 'refs/olddonkey-loop/extra'
                if kind == 'loose':
                    lab.git_at(scratch, 'update-ref', extra, tip)
                elif kind == 'packed':
                    lab.packed(scratch, [f'{tip} {extra}'])
                elif kind == 'case-variant':
                    lab.packed(scratch, [f'{tip} refs/olddonkey-loop/ANCHOR'])
                elif kind == 'symbolic':
                    lab.git_at(scratch, 'symbolic-ref', extra, tools.ANCHOR_REF)
                elif kind == 'dangling-symbolic':
                    lab.git_at(scratch, 'symbolic-ref', extra, 'refs/heads/missing')
                else:
                    lab.git_at(scratch, 'update-ref', 'refs/heads/target', tip)
                    lab.git_at(scratch, 'symbolic-ref', tools.ANCHOR_REF, 'refs/heads/target')
                before = lab.git('for-each-ref', '--format=%(objectname) %(refname)')
                token = store.begin('epoch-rotation', PRINCIPAL)
                try:
                    with self.assertRaises(store.AuthorityError) as error:
                        store._run_sink(token, 'git.push-anchor', scratch=scratch, remote=lab.url, commit=tip)
                    self.assertEqual(error.exception.code, 'anchor-scratch')
                    self.assertIsNone(token.permit)
                finally:
                    store.spend(token)
                self.assertEqual(lab.git('for-each-ref', '--format=%(objectname) %(refname)'), before)

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


class RealGitReviewTests(unittest.TestCase):
    def test_rotate_absent_readback_is_pending_then_classifies_as_c03400d(self):
        with RealAuthority() as lab:
            real_readback, seen = store.readback, {}
            def delete_after_push(*args, **kwargs):
                seen['pushed'] = lab.tip()
                self.assertEqual(seen['pushed'], kwargs['commit'])
                lab.git('update-ref', '-d', tools.ANCHOR_REF)
                return real_readback(*args, **kwargs)
            with mock.patch.object(store, 'readback', side_effect=delete_after_push):
                with self.assertRaises(store.AuthorityError) as error:
                    lab.perform('rotate')
            self.assertEqual((error.exception.code, error.exception.exit_code), ('pending', 5))
            self.assertIn('readback cannot confirm the push', error.exception.message)
            intent = lab.store / 'intent'
            self.assertEqual(json.loads(intent.read_bytes())['anchor_commit'], seen['pushed'])
            before = lab.snapshot(lab.store)
            # Frozen by replaying this same real-Git deletion schedule against
            # c03400d under a scratch HOME. Readback's pending exit does not
            # change the later absent-anchor classification, even with intent.
            expected = {'loop-authority': ('quarantined', 'anchor-absent', 6),
                        'loop-authority-verify': ('quarantined', None, 6)}
            for name, args in [('loop-authority', ['verify']), ('loop-authority-verify', [])]:
                result = subprocess.run(['bash', str(ROOT / 'scripts' / name), *args],
                                        capture_output=True, env=dict(os.environ))
                value = json.loads(result.stdout)
                self.assertEqual((value['state'], value.get('rule'), result.returncode), expected[name])
                self.assertEqual(value['table'], 'A2.3 absent ref once active exists')
                self.assertNotIn(b'Traceback', result.stderr)
            self.assertEqual(lab.snapshot(lab.store), before)
            self.assertFalse((lab.store / 'quarantine').exists())

    def test_readback_present_different_commit_stays_refused(self):
        with RealAuthority() as lab:
            parent = lab.tip()
            real_readback = store.readback
            def rewind_after_push(*args, **kwargs):
                self.assertNotEqual(lab.tip(), parent)
                lab.git('update-ref', tools.ANCHOR_REF, parent)
                return real_readback(*args, **kwargs)
            with mock.patch.object(store, 'readback', side_effect=rewind_after_push):
                with self.assertRaises(store.AuthorityError) as error:
                    lab.perform('rotate')
            self.assertEqual((error.exception.code, error.exception.exit_code), ('readback', 4))
            self.assertEqual(lab.tip(), parent)
            lab.agree(self, 'pending', 5)

    def test_bootstrap_fetch_absent_after_advertisement_is_pending(self):
        with RealAuthority() as lab:
            home = lab.base / 'bootstrap-home'
            home.mkdir()
            lab.git('update-ref', '-d', tools.ANCHOR_REF)
            lab.reset()  # Clear old-HOME scratch before entering the new HOME.
            with mock.patch.dict(os.environ, {'HOME': str(home)}), contextlib.ExitStack() as scope:
                scope.callback(lab.reset)
                with mock.patch.object(store, 'readback', side_effect=store.AuthorityError(
                        'pending', 'stop after the real genesis push', store.EXIT_PENDING)):
                    with self.assertRaises(store.AuthorityError):
                        lab.perform('genesis', lab.url)
                tip = lab.tip()
                auth = home / '.config/olddonkey-loop/authority'
                self.assertTrue((auth / 'genesis.intent').exists())
                self.assertFalse((auth / 'active').exists())
                env = lab.wrapper("if 'ls-remote' in a:\n"
                    "    done = subprocess.run([REAL] + a)\n"
                    + "    subprocess.run([REAL, '--git-dir', REMOTE, 'update-ref', '-d', "
                    + repr(tools.ANCHOR_REF) + "], check=True)\n    sys.exit(done.returncode)\n")
                for name, args in [('loop-authority', ['verify']), ('loop-authority-verify', [])]:
                    lab.git('update-ref', tools.ANCHOR_REF, tip)
                    result = subprocess.run(['bash', str(ROOT / 'scripts' / name), *args],
                                            capture_output=True, env=dict(os.environ, **env))
                    self.assertEqual(result.returncode, 5, (name, result.stdout, result.stderr))
                    value = json.loads(result.stdout)
                    self.assertEqual((value['state'], value['table']), ('genesis-pending', 'A2.3 row 4'))
                lab.reset()  # Remove bootstrap scratch before restoring HOME.

    def test_replay_parent_absent_is_pending(self):
        with RealAuthority() as lab:
            # Leave a real complete frame/intent at ptr(L - 1), then remove
            # the parent between recovery's observation and object rebuilding.
            with mock.patch.object(store, 'push_anchor', side_effect=store.AuthorityError(
                    'pending', 'stop before the rotation push', store.EXIT_PENDING)):
                with self.assertRaises(store.AuthorityError):
                    lab.perform('rotate')
            lab.agree(self, 'pending', 5)
            before, real_replay = lab.snapshot(lab.store), recover._replay
            def delete_before_replay(plan, scratch_factory):
                lab.git('update-ref', '-d', tools.ANCHOR_REF)
                return real_replay(plan, scratch_factory)
            with mock.patch.object(recover, '_replay', side_effect=delete_before_replay):
                with self.assertRaises(store.AuthorityError) as error, store.WriterLock():
                    recover.recover()
            self.assertEqual((error.exception.code, error.exception.exit_code), ('pending', 5))
            self.assertEqual(lab.snapshot(lab.store), before)

    def test_name_race_same_advertised_commit_is_committed(self):
        with RealAuthority() as lab:
            lab.perform('rotate')
            tip, parent = lab.tip(), lab.git('rev-parse', lab.tip() + '^')
            trace = lab.base / 'name-race.jsonl'
            env = lab.wrapper('import json\nTRACE = ' + repr(str(trace)) + '\n'
                "if 'ls-remote' in a:\n"
                + "    subprocess.run([REAL, '--git-dir', REMOTE, 'update-ref', "
                + repr(tools.ANCHOR_REF) + ', ' + repr(tip) + "], check=True)\n"
                "    done = subprocess.run([REAL] + a, capture_output=True)\n"
                "    sys.stdout.buffer.write(done.stdout)\n    sys.stderr.buffer.write(done.stderr)\n"
                + "    exact = [line.split('\\t')[0] for line in done.stdout.decode().splitlines() if line.split('\\t')[-1] == "
                + repr(tools.ANCHOR_REF) + "]\n"
                "    with open(TRACE, 'a') as f: f.write(json.dumps(['advertised', exact]) + '\\n')\n"
                + "    subprocess.run([REAL, '--git-dir', REMOTE, 'update-ref', '-d', "
                + repr(tools.ANCHOR_REF) + "], check=True)\n    sys.exit(done.returncode)\n"
                "if 'fetch' in a:\n    done = subprocess.run([REAL] + a)\n"
                "    root = a[a.index('-C') + 1]\n"
                "    oid = subprocess.check_output([REAL, '-C', root, 'rev-parse', 'refs/readback/anchor']).decode().strip()\n"
                "    with open(TRACE, 'a') as f: f.write(json.dumps(['fetched', oid]) + '\\n')\n"
                "    sys.exit(done.returncode)\n")
            for tail, state, code in ((tip, 'committed', 0), (parent, 'pending', 5)):
                with self.subTest(tail=tail):
                    lab.git('update-ref', 'refs/heads/' + tools.ANCHOR_REF, tail)
                    for name, args in [('loop-authority', ['verify']), ('loop-authority-verify', [])]:
                        trace.write_text('')
                        result = subprocess.run(['bash', str(ROOT / 'scripts' / name), *args],
                                                capture_output=True, env=dict(os.environ, **env))
                        self.assertEqual(result.returncode, code, (name, result.stdout, result.stderr))
                        self.assertEqual(json.loads(result.stdout)['state'], state)
                        samples = [json.loads(line) for line in trace.read_text().splitlines()]
                        advertised = [value for kind, value in samples if kind == 'advertised']
                        fetched = [value for kind, value in samples if kind == 'fetched']
                        self.assertTrue(advertised)
                        self.assertTrue(all(value == [tip] for value in advertised))
                        self.assertEqual(fetched, [tail])
                        if state == 'committed':
                            self.assertEqual(fetched, [tip])  # The accepted id is exactly the advertisement.
                        self.assertNotEqual(lab.git_at(lab.remote, 'show-ref', '--verify', tools.ANCHOR_REF,
                                                      check=False).returncode, 0)

    def test_prefix_siblings_writer_verifier_agreement(self):
        for kind in ('case-variant', 'fifty', 'unrelated'):
            with self.subTest(kind=kind), RealAuthority() as lab:
                original = lab.tip()
                unrelated = lab.other_commit(lab.remote) if kind == 'unrelated' else None
                siblings = ({'refs/olddonkey-loop/ANCHOR': original} if kind == 'case-variant' else
                            {f'refs/olddonkey-loop/s{i:02}': original for i in range(50)} if kind == 'fifty' else
                            {'refs/olddonkey-loop/other': unrelated})
                lab.packed(lab.remote, [f'{oid} {ref}' for ref, oid in siblings.items()])
                trace = lab.base / 'fetches.jsonl'
                env = lab.wrapper("if 'fetch' in a:\n"
                    "    import json\n    done = subprocess.run([REAL] + a)\n"
                    "    root = a[a.index('-C') + 1]\n"
                    "    refs = subprocess.check_output([REAL, '-C', root, 'for-each-ref', '--format=%(refname)']).decode().splitlines()\n"
                    + '    other = ' + repr(unrelated) + '\n'
                    "    missing = other is None or subprocess.run([REAL, '-C', root, 'cat-file', '-e', other], capture_output=True).returncode != 0\n"
                    + '    with open(' + repr(str(trace)) + ", 'a') as f: f.write(json.dumps([refs, missing]) + '\\n')\n"
                    "    sys.exit(done.returncode)\n")
                lab.agree(self, 'committed', 0, env)
                for command, args in [('rotate', ()), ('revoke', (1,))]:
                    lab.perform(command, *args)
                    lab.agree(self, 'committed', 0, env)
                    present = dict(line.split(' ', 1)[::-1] for line in
                                   lab.git('for-each-ref', '--format=%(objectname) %(refname)',
                                           'refs/olddonkey-loop/').splitlines())
                    self.assertEqual({ref: present[ref] for ref in siblings}, siblings)
                samples = [json.loads(line) for line in trace.read_text().splitlines()]
                self.assertGreaterEqual(len(samples), 6)  # Both readers, at all three states.
                for refs, missing in samples:
                    self.assertEqual(refs, [tools.READBACK_REF])
                    self.assertTrue(missing, 'unrelated sibling object was downloaded')

    def test_reused_scratch_never_returns_stale_readback(self):
        with RealAuthority() as lab:
            tip = lab.tip()
            scratch = lab.scratch()
            self.assertEqual(anchor.fetch(scratch, lab.url), tip)
            lab.git('update-ref', '-d', tools.ANCHOR_REF)
            # Prove the old file is still there, but the public API returns absent.
            self.assertEqual((Path(scratch) / tools.READBACK_REF).read_text().strip(), tip)
            self.assertIsNone(anchor.fetch(scratch, lab.url))
            # Even the underlying exact Git fetch fails, unlike the old pattern.
            result = tools.run('git.fetch-anchor', scratch=scratch, remote=lab.url)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNone(anchor.fetch(scratch, lab.url))

    def test_regenesis_anchor_deleted_at_challenge_writes_no_intent_or_frame(self):
        with RealAuthority() as lab:
            lab.perform('revoke', 1)
            before = lab.snapshot(lab.store)
            active = (lab.auth / 'active').read_bytes()
            def delete(_envelope):
                lab.git('update-ref', '-d', tools.ANCHOR_REF)
            with mock.patch.object(ceremony, 'challenge', side_effect=delete):
                with self.assertRaises(store.AuthorityError) as error:
                    lab.perform('regenesis')
            self.assertEqual(error.exception.exit_code, 4)
            self.assertEqual(before, lab.snapshot(lab.store))
            self.assertEqual((lab.auth / 'active').read_bytes(), active)
            self.assertFalse((lab.auth / 'regenesis.intent').exists())
            new = [p for p in (lab.auth / 'stores').iterdir() if p != lab.store]
            self.assertEqual(len(new), 1)  # Unpublished keys may remain.
            self.assertFalse(any(p.read_bytes() for p in new[0].glob('log/*')))

    def test_remote_moved_between_advertisement_and_fetch_is_pending(self):
        with RealAuthority() as lab:
            lab.perform('rotate')
            tip, parent = lab.tip(), lab.git('rev-parse', lab.tip() + '^')
            for advertised, fetched in ((tip, parent), (parent, tip)):
                with self.subTest(advertised=advertised):
                    env = lab.wrapper("if 'ls-remote' in a:\n"
                        + "    subprocess.run([REAL, '--git-dir', REMOTE, 'update-ref', " + repr(tools.ANCHOR_REF)
                        + ', ' + repr(advertised) + "], check=True)\n"
                        "    done = subprocess.run([REAL] + a)\n"
                        + "    subprocess.run([REAL, '--git-dir', REMOTE, 'update-ref', " + repr(tools.ANCHOR_REF)
                        + ', ' + repr(fetched) + "], check=True)\n    sys.exit(done.returncode)\n")
                    lab.agree(self, 'pending', 5, env)
            lab.git('update-ref', tools.ANCHOR_REF, tip)
            lab.agree(self, 'committed', 0)

    def test_ls_remote_and_fetch_timeouts_are_pending(self):
        with RealAuthority() as lab:
            package = lab.base / 'package'
            shutil.copytree(ROOT / 'lib', package / 'lib')
            shutil.copytree(ROOT / 'scripts', package / 'scripts')
            p = package / 'lib/loopauth/tools.py'
            p.write_text(p.read_text().replace('REMOTE_TIMEOUT = 120', 'REMOTE_TIMEOUT = 0.5'))
            p = package / 'scripts/loop-authority-verify.py'
            p.write_text(p.read_text().replace('timeout=120 if form', 'timeout=0.5 if form'))
            for form in ('ls-remote', 'fetch'):
                with self.subTest(form=form):
                    env = lab.wrapper('if ' + repr(form) + " in a:\n"
                        "    done = subprocess.run([REAL] + a)\n    time.sleep(2)\n    sys.exit(done.returncode)\n")
                    lab.agree(self, 'pending', 5, env, package / 'scripts')

    def test_sink_commit_required_validated_and_actually_checked(self):
        with RealAuthority() as lab:
            tip, scratch = lab.tip(), lab.scratch()
            anchor.fetch(scratch, lab.url)
            anchor.prepare_push(scratch, tip)
            for commit in (None, 'invalid', '0' * 40):
                with self.subTest(commit=commit):
                    params = {'scratch': scratch, 'remote': lab.url}
                    if commit is not None:
                        params['commit'] = commit
                    token = store.begin('epoch-rotation', PRINCIPAL)
                    try:
                        with self.assertRaises((tools.ToolError, store.AuthorityError)) as error:
                            store._run_sink(token, 'git.push-anchor', **params)
                        self.assertEqual(error.exception.code, 'anchor-scratch' if commit == '0' * 40 else 'params')
                    finally:
                        store.spend(token)
                    self.assertEqual(lab.tip(), tip)
            token = store.begin('epoch-rotation', PRINCIPAL)
            try:
                result = store._run_sink(token, 'git.push-anchor', scratch=scratch, remote=lab.url, commit=tip)
                self.assertEqual(result.returncode, 0, result.stderr)
            finally:
                store.spend(token)

    def test_push_binding_ref_repointed_after_prepare_is_refused(self):
        with RealAuthority() as lab:
            before = lab.tip()
            real_sink, seen = store._run_sink, {}
            def tamper(token, command_id, stdin=b'', **params):
                if command_id == 'git.push-anchor':
                    scratch = params['scratch']
                    seen['bound'] = params['commit']
                    # Every interference command is a token-less table entry.
                    blob = tools.run('git.hash-object', scratch=scratch, stdin=b'unrelated\n').stdout.strip().decode()
                    tree = tools.run('git.mktree', scratch=scratch, stdin=f'100644 blob {blob}\tother\n'.encode()).stdout.strip().decode()
                    seen['other'] = tools.run('git.commit-tree', scratch=scratch, tree=tree, parent=before,
                        message=f'anchor {lab.store.name} g1 s2', seq=2).stdout.strip().decode()
                    tools.run('git.update-anchor', scratch=scratch, commit=seen['other'])
                return real_sink(token, command_id, stdin, **params)
            with mock.patch.object(store, '_run_sink', side_effect=tamper):
                with self.assertRaises(store.AuthorityError) as error:
                    lab.perform('rotate')
            self.assertEqual(error.exception.code, 'anchor-scratch')
            self.assertNotEqual(seen['bound'], seen['other'])
            self.assertEqual(lab.tip(), before)
            lab.agree(self, 'pending', 5)

    def test_rotate_regenesis_marker_crashes_are_real_and_recoverable(self):
        for command in ('rotate', 'regenesis'):
            for point in ('fs-create-marker-after-temp-fsync', 'fs-create-marker-after-rename'):
                with self.subTest(command=command, point=point), RealAuthority() as lab:
                    lab.git('update-ref', '-d', tools.ANCHOR_REF)
                    before = (lab.store / 'log/segment-000001.olf').read_bytes()
                    child = ("import sys; sys.path.insert(0, " + repr(str(ROOT / 'lib')) + ")\n"
                        "from loopauth import ceremony, store\n"
                        "ceremony.challenge = lambda envelope: None\n"
                        + 'store.configure_crash(' + repr(command) + ')\n'
                        "with store.WriterLock():\n    ceremony." + command + '(' + repr(PRINCIPAL) + ')\n')
                    result = subprocess.run([sys.executable, '-c', child], capture_output=True,
                                            env=dict(os.environ, LOOP_AUTHORITY_CRASH_AT=point))
                    self.assertEqual(result.returncode, 137, result.stderr)
                    self.assertEqual((lab.store / 'quarantine').exists(), point.endswith('after-rename'))
                    self.assertEqual((lab.store / 'log/segment-000001.olf').read_bytes(), before)
                    self.assertFalse((lab.auth / 'regenesis.intent').exists())
                    with store.WriterLock():
                        first, second = recover.recover(), recover.recover()
                    self.assertEqual((first.state, second.state), ('quarantined', 'quarantined'))
                    lab.agree(self, 'quarantined', 6)


if __name__ == '__main__':
    unittest.main()
