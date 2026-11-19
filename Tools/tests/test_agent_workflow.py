"""エージェント共通の端末操作とマージキューを、実端末や本物のmainに触れずに検証する。"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SimulatorWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        (self.root / 'Tools').mkdir()
        for name in ('sim.sh', 'sim-lease-guard.py'):
            shutil.copy2(ROOT / 'Tools' / name, self.root / 'Tools' / name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}')
        self.devices = {'devices': {'runtime': [
            {'name': 'Scia 1', 'udid': '11111111-1111-1111-1111-111111111111'},
            {'name': 'Scia 2', 'udid': '22222222-2222-2222-2222-222222222222'},
        ]}}
        self.script('xcrun', '#!/usr/bin/env python3\nimport sys\nassert sys.argv[1:] == ["simctl", "list", "devices", "-j"], sys.argv\nprint('+repr(json.dumps(self.devices))+')\n')
        self.record = self.root / 'axe-arguments.json'
        self.script('axe', '#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\nPath('+repr(str(self.record))+').write_text(json.dumps(sys.argv[1:]))\n')
        self.locks = self.root / '.git/sim-locks'
        self.locks.mkdir()

    def script(self, name, content):
        path = self.bin / name
        path.write_text(content)
        path.chmod(0o755)

    def run_sim(self, *arguments):
        return subprocess.run(['Tools/sim.sh', *arguments], cwd=self.root, env=self.env, text=True, capture_output=True)

    def lease(self, name='Scia 1', owner=None):
        (self.locks / f'{name}.lease').write_text(f'{int(time.time())} {owner or self.root}\n')

    def test_axe_uses_only_leased_device(self):
        result = self.run_sim('axe', 'Scia 1', 'tap', '-x', '20', '-y', '30')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.record.exists())
        self.lease()
        result = self.run_sim('axe', 'Scia 1', 'tap', '-x', '20', '-y', '30')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(self.record.read_text()), ['tap', '--udid', self.devices['devices']['runtime'][0]['udid'], '-x', '20', '-y', '30'])
        self.record.unlink()
        self.assertNotEqual(self.run_sim('axe', 'Scia 2', 'tap', '-x', '20', '-y', '30').returncode, 0)
        self.assertFalse(self.record.exists())

    def test_axe_type_keeps_target_before_argument_terminator(self):
        self.lease()
        result = self.run_sim('axe', 'Scia 1', 'type', '--', '--help')
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads(self.record.read_text())
        self.assertLess(arguments.index('--udid'), arguments.index('--'))
        self.assertEqual(arguments[arguments.index('--') + 1:], ['--help'])

    def test_axe_rejects_target_override_and_unbounded_commands(self):
        self.lease()
        for arguments in [('tap', '--udid', 'other'), ('tap', '--udid=other'), ('batch', 'steps.json'), ('agent', 'tap'), ('clipboard', 'paste')]:
            with self.subTest(arguments=arguments):
                self.assertNotEqual(self.run_sim('axe', 'Scia 1', *arguments).returncode, 0)
                self.assertFalse(self.record.exists())

    def test_hook_blocks_direct_axe_for_both_hosts(self):
        for host in ('claude', 'codex'):
            config_path = ROOT / ('.claude/settings.json' if host == 'claude' else '.codex/hooks.json')
            hook = json.loads(config_path.read_text())['hooks']['PreToolUse'][0]['hooks'][0]['command']
            for command in ('axe tap -x 20 -y 30 --udid anything', 'bash -c "axe swipe --udid anything"', 'xcrun simctl boot "Scia 1"', 'if true; then axe tap --udid other; fi', 'for x in 1; do axe tap --udid other; done', 'axe type --udid other -- --help'):
                payload = {'tool_name': 'Bash', 'tool_input': {'command': command}, 'cwd': str(self.root), 'session_id': host}
                result = subprocess.run(hook, shell=True, input=json.dumps(payload), cwd=self.root, env=dict(self.env, CLAUDE_PROJECT_DIR=str(self.root)), text=True, capture_output=True)
                self.assertEqual(result.returncode, 2, (command, result.stderr))

    def test_hook_allows_wrapper_and_read_only_commands(self):
        for command in ("Tools/sim.sh axe 'Scia 1' tap -x 20 -y 30", 'axe list-simulators', 'axe tap --help', "rg 'axe tap' Tools", "echo 'axe tap'", 'xcrun simctl list devices'):
            payload = {'tool_name': 'Bash', 'tool_input': {'command': command}, 'cwd': str(self.root)}
            result = subprocess.run(['python3', 'Tools/sim-lease-guard.py'], input=json.dumps(payload), cwd=self.root, env=self.env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, (command, result.stderr))

    def test_codex_background_process_is_associated_with_its_worktree(self):
        self.script('ps', '#!/bin/sh\nprintf "%s\\n" "900001 1 codex app-server" "900002 900001 xcrun simctl io Scia 1 recordVideo movie.mp4"\n')
        self.script('lsof', '#!/bin/sh\nprintf "n%s\\n" "$SCIA_TEST_PROCESS_CWD"\n')
        self.env['SCIA_TEST_PROCESS_CWD'] = str(self.root)
        result = self.run_sim('__acquire_try', str(self.root), 'Scia 1')
        self.assertEqual(result.returncode, 0, result.stderr)
        (self.locks / 'Scia 1.lease').unlink()
        other = self.root / 'other'
        subprocess.run(['git', 'init', '-q', str(other)], check=True)
        self.env['SCIA_TEST_PROCESS_CWD'] = str(other)
        result = self.run_sim('__acquire_try', str(self.root), 'Scia 1')
        self.assertEqual(result.returncode, 75, result.stderr)


class MergeQueueTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'repo'
        self.root.mkdir()
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Workflow test')
        self.git('config', 'user.email', 'workflow@example.invalid')
        (self.root / 'Tools').mkdir()
        shutil.copy2(ROOT / 'Tools/merge-queue.sh', self.root / 'Tools/merge-queue.sh')
        # キューのGit操作とロックは実物を使い、ビルドと人による承認の境界だけを置き換える。
        self.script('check-stamp.sh', '#!/bin/sh\nprintf "make check\\nmake test\\n"\n')
        (self.root / 'Tools/generate-app-info.py').write_text('import sys\nassert sys.argv[1:] == ["--check"]\n')
        self.script('human-review.sh', '#!/bin/sh\n[ "${SCIA_TEST_HUMAN_MISSING:-0}" != 1 ] || echo README.md\nexit 0\n')
        self.script('test-dispatch.sh', '#!/bin/sh\n[ "$1 $2" = "dispatch check-test" ] || exit 90\nprintf "%s\\n" "$(git branch --show-current)" >> "$(git rev-parse --git-common-dir)/tested"\nexit "${SCIA_TEST_CHECK_EXIT:-0}"\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        self.initial = self.git('rev-parse', 'HEAD')

    def git(self, *arguments, cwd=None):
        return subprocess.check_output(['git', *arguments], cwd=cwd or self.root, text=True, stderr=subprocess.PIPE).strip()

    def script(self, name, content):
        path = self.root / 'Tools' / name
        path.write_text(content)
        path.chmod(0o755)

    def branch(self, name):
        work = self.root.parent / name
        self.git('worktree', 'add', '-q', '-b', name, str(work), 'main')
        (work / name).write_text(name)
        self.git('add', name, cwd=work)
        self.git('commit', '-qm', name, cwd=work)
        return work

    def run_queue(self, work, *dependencies, **env):
        return subprocess.run(['Tools/merge-queue.sh', 'run', *dependencies], cwd=work,
                              env=dict(os.environ, **env), text=True, capture_output=True, timeout=30)

    def test_success_checks_and_fast_forwards_local_main(self):
        work = self.branch('feature')
        result = self.run_queue(work)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git('rev-parse', 'main'), self.git('rev-parse', 'feature'))
        self.assertEqual((self.root / '.git/tested').read_text().splitlines(), ['feature'])
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_failed_check_and_missing_human_approval_leave_main_unchanged(self):
        work = self.branch('feature')
        for environment, expected in [({'SCIA_TEST_CHECK_EXIT': '1'}, 4), ({'SCIA_TEST_HUMAN_MISSING': '1'}, 6)]:
            with self.subTest(environment=environment):
                result = self.run_queue(work, **environment)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(self.git('rev-parse', 'main'), self.initial)

    def test_dirty_and_detached_worktrees_are_not_merged(self):
        work = self.branch('feature')
        (work / 'dirty').write_text('dirty')
        self.assertEqual(self.run_queue(work).returncode, 2)
        (work / 'dirty').unlink()
        self.git('checkout', '--detach', '-q', cwd=work)
        self.assertNotEqual(self.run_queue(work).returncode, 0)
        self.assertEqual(self.git('rev-parse', 'main'), self.initial)

    def test_dependency_uses_the_same_queue_across_worktrees(self):
        first = self.branch('first')
        second = self.branch('second')
        with tempfile.TemporaryFile(mode='w+') as output:
            pending = subprocess.Popen(['Tools/merge-queue.sh', 'run', 'first'], cwd=second, stdout=output, stderr=output)
            try:
                deadline = time.monotonic() + 5
                queue = self.root / '.git/scia-merge-queue'
                while not list(queue.glob('[0-9]*')):
                    self.assertIsNone(pending.poll())
                    self.assertLess(time.monotonic(), deadline)
                    time.sleep(0.05)
                self.assertEqual(self.git('rev-parse', 'main'), self.initial)
                result = self.run_queue(first)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                code = pending.wait(timeout=15)
                output.seek(0)
                self.assertEqual(code, 0, output.read())
            finally:
                if pending.poll() is None:
                    pending.terminate()
                    pending.wait(timeout=10)
        self.assertEqual((self.root / '.git/tested').read_text().splitlines(), ['first', 'second'])
        self.assertTrue((self.root / 'first').is_file())
        self.assertTrue((self.root / 'second').is_file())
        self.assertEqual(self.git('rev-parse', 'main'), self.git('rev-parse', 'second'))


if __name__ == '__main__':
    unittest.main()
