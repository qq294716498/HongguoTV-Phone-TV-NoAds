"""Run isolated Win32 process tests against the production instance guard.

The only windows/processes controlled by this test are its own synthetic fixture.
MSVC is required by default on Windows; --cxx/CXX supports LLVM-MinGW locally.
Non-Windows unittest discovery records explicit skips, never native passes.
"""
import argparse
import ctypes
import datetime
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REQUESTED_CXX = os.environ.get('CXX')
FORCE_MSVC = False
COMPILER = {}


def wait_for(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.025)
    raise AssertionError('Synthetic fixture condition was not reached before timeout')


def read_json(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (FileNotFoundError, json.JSONDecodeError, PermissionError):
        return None


def run_compile(command, environment, directory):
    result = subprocess.run(command, cwd=directory, env=environment,
                            capture_output=True, text=True, errors='replace', timeout=120)
    if result.returncode:
        raise RuntimeError('Native fixture compilation failed:\n' + repr(command) + '\n' +
                           result.stdout + '\n' + result.stderr)


def msvc_environment():
    environment = os.environ.copy()
    if shutil.which('cl.exe') and shutil.which('rc.exe'):
        return environment
    vswhere = Path(os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')) / \
        'Microsoft Visual Studio/Installer/vswhere.exe'
    if not vswhere.is_file():
        raise RuntimeError('Native tests require MSVC C++ tools and Windows SDK; vswhere is absent. '
                           'Install the C++ workload or supply --cxx with a Windows LLVM-MinGW compiler.')
    found = subprocess.run([str(vswhere), '-latest', '-products', '*', '-requires',
                            'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
                            '-property', 'installationPath'], capture_output=True,
                           text=True, errors='replace', check=True).stdout.strip()
    developer = Path(found) / 'Common7/Tools/VsDevCmd.bat' if found else None
    if not developer or not developer.is_file():
        raise RuntimeError('Native tests require MSVC C++ tools and Windows SDK; the installed '
                           'Visual Studio has no x64 C++ workload. This is not a skipped/passed native test.')
    command = '"{}" -no_logo -arch=x64 -host_arch=x64 >nul && set'.format(developer)
    prepared = subprocess.run(['cmd.exe', '/d', '/s', '/c', command], capture_output=True,
                              text=True, errors='replace', check=True)
    for line in prepared.stdout.splitlines():
        if '=' in line and not line.startswith('='):
            key, value = line.split('=', 1)
            environment[key.upper()] = value
    if not shutil.which('cl.exe', path=environment.get('PATH')) or \
            not shutil.which('rc.exe', path=environment.get('PATH')):
        raise RuntimeError('VsDevCmd did not expose cl.exe and rc.exe; native tests cannot run.')
    return environment


def compile_fixtures(directory):
    global COMPILER
    if REQUESTED_CXX and not FORCE_MSVC:
        compiler = shutil.which(REQUESTED_CXX) or REQUESTED_CXX
        if not Path(compiler).is_file():
            raise RuntimeError('Requested native compiler does not exist: ' + compiler)
        toolbin = Path(compiler).parent
        environment = os.environ.copy()
        environment['PATH'] = str(toolbin) + os.pathsep + environment.get('PATH', '')
        resource_compiler = toolbin / 'llvm-rc.exe'
        if not resource_compiler.is_file():
            raise RuntimeError('LLVM-MinGW tests require sibling llvm-rc.exe: ' + str(toolbin))
        compiler_args = [compiler, '-std=c++17', '-municode', '-static', '-O1',
                         '-DUNICODE', '-D_UNICODE', '-DNOMINMAX', '-Wall', '-Wextra', '-Werror']
        COMPILER = {'family': 'LLVM-MinGW', 'path': str(compiler)}
    else:
        environment = msvc_environment()
        compiler = shutil.which('cl.exe', path=environment.get('PATH'))
        resource_compiler = shutil.which('rc.exe', path=environment.get('PATH'))
        compiler_args = [compiler, '/nologo', '/std:c++17', '/EHsc', '/utf-8',
                         '/DUNICODE', '/D_UNICODE', '/DNOMINMAX', '/W4', '/WX', '/wd4100']
        COMPILER = {'family': 'MSVC', 'path': str(compiler)}
    source = ROOT / 'scripts/tests/windows_single_instance_harness.cpp'
    guard = ROOT / 'windows/runner/single_instance.cpp'
    resource = ROOT / 'scripts/tests/windows_single_instance_harness.rc'
    for kind in ['current', 'legacy']:
        output = directory / kind
        output.mkdir()
        compiled_resource = output / 'fixture.res'
        resource_args = [str(resource_compiler), '/nologo', '/fo', str(compiled_resource)]
        if kind == 'legacy':
            resource_args += ['/d', 'LEGACY_FIXTURE']
        resource_args.append(str(resource))
        run_compile(resource_args, environment, output)
        executable = output / 'single_instance_harness.exe'
        if COMPILER['family'] == 'MSVC':
            command = compiler_args + ['/I' + str(ROOT / 'windows/runner'), str(source),
                                       str(guard), str(compiled_resource), '/Fe:' + str(executable),
                                       '/link', 'user32.lib', 'advapi32.lib', 'version.lib']
        else:
            command = compiler_args + ['-I', str(ROOT / 'windows/runner'), str(source),
                                       str(guard), str(compiled_resource), '-o', str(executable),
                                       '-luser32', '-ladvapi32', '-lversion']
        run_compile(command, environment, output)
    return environment


class FixtureProcess:
    def __init__(self, suite, executable=None, **options):
        self.suite = suite
        self.sequence = 0
        self.report = suite.directory / ('report-' + uuid.uuid4().hex + '.json')
        self.control = self.report.with_suffix('.control')
        command = [str(executable or suite.current), '--test-isolation',
                   '--application-id', suite.identity, '--report', str(self.report),
                   '--control', str(self.control), '--lifetime', '30000']
        for key, value in options.items():
            command += ['--' + key.replace('_', '-'), str(value)]
        self.process = subprocess.Popen(command, env=suite.environment,
                                        creationflags=subprocess.CREATE_NO_WINDOW,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        suite.processes.append(self)

    def state(self):
        return read_json(self.report)

    def wait_state(self, predicate=lambda state: True, timeout=8):
        return wait_for(lambda: (lambda state: state if state and predicate(state) else None)(self.state()), timeout)

    def command(self, name):
        self.sequence += 1
        self.control.write_text('{} {}\n'.format(self.sequence, name), encoding='ascii')
        return self.wait_state(lambda state: state['command'] >= self.sequence)

    def exit_code(self, timeout=5):
        return self.process.wait(timeout=timeout)

    def close(self):
        if self.process.poll() is None:
            try:
                self.command('close')
                self.process.wait(timeout=4)
            except (AssertionError, subprocess.TimeoutExpired):
                self.process.terminate()  # Only this Popen-created synthetic fixture.
                self.process.wait(timeout=4)
        self.process.communicate(timeout=2)


@unittest.skipUnless(os.name == 'nt', 'Win32 native process/window tests require Windows')
class WindowsSingleInstanceNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='hongguo-native-isolation-')
        cls.base = Path(cls.temporary.name)
        try:
            cls.environment = compile_fixtures(cls.base)
        except Exception:
            cls.temporary.cleanup()
            raise
        cls.current_source = cls.base / 'current/single_instance_harness.exe'
        cls.legacy_source = cls.base / 'legacy/single_instance_harness.exe'

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.identity = 'HongguoTV.NativeHarness.' + uuid.uuid4().hex
        self.directory = self.base / uuid.uuid4().hex
        self.directory.mkdir()
        self.processes = []
        self.current = self.copy_executable(self.current_source, 'install-A')

    def tearDown(self):
        for process in reversed(self.processes):
            process.close()

    def copy_executable(self, source, directory):
        target = self.directory / directory / 'single_instance_harness.exe'
        target.parent.mkdir()
        shutil.copy2(source, target)
        return target

    def launch(self, **options):
        return FixtureProcess(self, **options)

    def owner(self, **options):
        process = self.launch(**options)
        state = process.wait_state(lambda value: value['result'] not in ['primary', 'legacy-owner'] or
                                   (value['hwnd'] and (value['attached'] or options.get('legacy'))))
        self.assertIn(state['result'], ['primary', 'legacy-owner'], state)
        return process

    def secondary(self, **options):
        process = self.launch(**options)
        state = process.wait_state()
        process.exit_code()
        return process, state

    def assert_paused(self, process):
        state = process.wait_state()
        self.assertTrue(state['paused'], state)
        self.assertEqual(state['toggles'], 0, state)

    def test_concurrent_launches_have_one_primary(self):
        processes = [self.launch(activation_timeout=2500) for _ in range(8)]
        states = [process.wait_state() for process in processes]
        self.assertEqual(sum(state['result'] == 'primary' for state in states), 1, states)
        self.assertTrue(all(state['result'] in ['primary', 'activated'] for state in states), states)
        owner = processes[next(i for i, state in enumerate(states) if state['result'] == 'primary')]
        owner.wait_state(lambda state: state['restores'] > 0)
        self.assert_paused(owner)

    def test_same_user_different_paths_share_identity(self):
        owner = self.owner()
        other_path = self.copy_executable(self.current_source, 'different-install-B')
        _, state = self.secondary(executable=other_path)
        self.assertEqual(state['result'], 'activated', state)
        self.assertEqual(state['mutex'], owner.state()['mutex'])
        self.assert_paused(owner)

    def test_hidden_tray_restore_preserves_pause(self):
        owner = self.owner()
        self.assertFalse(owner.command('hide')['visible'])
        _, state = self.secondary()
        self.assertEqual(state['result'], 'activated', state)
        owner.wait_state(lambda value: value['visible'] and value['restores'] == 1)
        self.assert_paused(owner)

    def test_minimized_restore_preserves_pause(self):
        owner = self.owner()
        self.assertTrue(owner.command('minimize')['minimized'])
        _, state = self.secondary()
        self.assertEqual(state['result'], 'activated', state)
        owner.wait_state(lambda value: not value['minimized'] and value['restores'] == 1)
        self.assert_paused(owner)

    def test_restore_waits_for_both_ready_signals(self):
        for order in [('desktop', 'frame'), ('frame', 'desktop')]:
            owner = self.owner(ready=0)
            _, state = self.secondary()
            self.assertEqual(state['result'], 'activated', state)
            queued = owner.wait_state(lambda value: value['pending'])
            self.assertEqual(queued['restores'], 0)
            first = owner.command(order[0])
            self.assertTrue(first['pending'], first)
            self.assertEqual(first['restores'], 0, first)
            final = owner.command(order[1])
            self.assertFalse(final['pending'], final)
            self.assertEqual(final['restores'], 1, final)
            self.assert_paused(owner)
            owner.close()

    def test_missing_ipc_window_is_bounded_and_then_recovers(self):
        owner = self.launch(attach_delay=1800)
        owner.wait_state(lambda state: state['result'] == 'primary' and state['hwnd'] > 0)
        process, state = self.secondary(activation_timeout=350)
        self.assertEqual(state['result'], 'blocked', state)
        self.assertNotEqual(process.exit_code(), 0)
        self.assertLess(state['elapsed_ms'], 1200, state)
        owner.wait_state(lambda value: value['attached'])
        _, retry = self.secondary()
        self.assertEqual(retry['result'], 'activated', retry)

    def test_hung_window_is_bounded(self):
        self.owner(hang_activation=1)
        process, state = self.secondary(activation_timeout=350, message_timeout=80)
        self.assertEqual(state['result'], 'blocked', state)
        self.assertNotEqual(process.exit_code(), 0)
        self.assertLess(state['elapsed_ms'], 1300, state)

    def test_legacy_hidden_and_minimized_restore_without_toggle(self):
        legacy = self.copy_executable(self.legacy_source, 'legacy-install')
        owner = self.owner(executable=legacy, legacy=1)
        for command in ['hide', 'minimize']:
            owner.command(command)
            _, state = self.secondary()
            self.assertEqual(state['result'], 'legacy', state)
            owner.wait_state(lambda value: value['visible'] and not value['minimized'])
            self.assert_paused(owner)
        self.assertEqual(owner.state()['restores'], 2)

    def test_legacy_without_window_blocks_new_client(self):
        legacy = self.copy_executable(self.legacy_source, 'legacy-no-window')
        self.launch(executable=legacy, legacy=1, no_window=1).wait_state()
        _, state = self.secondary()
        self.assertEqual(state['result'], 'blocked', state)
        self.assertLess(state['elapsed_ms'], 1300, state)

    def test_normal_and_abnormal_exit_release_mutex(self):
        owner = self.owner()
        original_mutex = owner.state()['mutex']
        owner.close()
        successor = self.owner()
        self.assertEqual(successor.state()['mutex'], original_mutex)
        successor.process.terminate()  # Deliberate crash of the synthetic child only.
        successor.exit_code()
        third = self.owner()
        self.assertEqual(third.state()['mutex'], original_mutex)

    def test_mutex_handle_is_not_inherited(self):
        child_report = self.directory / 'inherited-child.json'
        child_control = self.directory / 'inherited-child.control'
        owner = self.owner(child_report=str(child_report), child_control=str(child_control))
        wait_for(lambda: read_json(child_report))
        child_state = read_json(child_report)
        self.assertEqual(child_state['result'], 'holder')
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        kernel.TerminateProcess.argtypes = [ctypes.c_void_p, ctypes.c_uint]
        child = kernel.OpenProcess(0x100001, False, child_state['pid'])
        self.assertTrue(child)
        try:
            owner.close()
            child_control.write_text('1 probe\n', encoding='ascii')
            measured = wait_for(lambda: (lambda value: value if value and value['command'] == 1
                                        else None)(read_json(child_report)))
            self.assertFalse(measured['mutex_exists'], measured)
            self.owner()
        finally:
            child_control.write_text('2 close\n', encoding='ascii')
            if kernel.WaitForSingleObject(child, 4000) != 0:
                kernel.TerminateProcess(child, 1)
                kernel.WaitForSingleObject(child, 4000)
            kernel.CloseHandle(child)

    def test_update_start_does_not_activate_or_ack_running_owner(self):
        owner = self.owner()
        process, state = self.secondary(update_start=1, update_wait=350)
        self.assertEqual(state['result'], 'blocked', state)
        self.assertFalse(state['ack'], state)
        self.assertNotEqual(process.exit_code(), 0)
        self.assertLess(state['elapsed_ms'], 1200, state)
        self.assertEqual(owner.state()['restores'], 0)
        self.assert_paused(owner)

    def test_update_start_waits_for_exit_then_owns_mutex(self):
        owner = self.owner()
        update = self.launch(update_start=1, update_wait=2500)
        time.sleep(0.15)
        self.assertIsNone(update.process.poll())
        self.assertIsNone(update.state())
        owner.close()
        state = update.wait_state(lambda value: value['attached'])
        self.assertEqual(state['result'], 'primary', state)
        self.assertTrue(state['ack'], state)

    def test_cross_path_owner_blocks_updater_child_without_ack(self):
        original = self.owner()
        original.close()
        other_path = self.copy_executable(self.current_source, 'other-install-B')
        competing = self.owner(executable=other_path)
        update, state = self.secondary(update_start=1, update_wait=350)
        self.assertEqual(state['result'], 'blocked', state)
        self.assertFalse(state['ack'], state)
        self.assertNotEqual(update.exit_code(), 0)
        self.assertEqual(competing.state()['restores'], 0)

    def test_update_start_refuses_legacy_owner(self):
        legacy = self.copy_executable(self.legacy_source, 'old-unaware-client')
        owner = self.owner(executable=legacy, legacy=1)
        update, state = self.secondary(update_start=1, update_wait=350)
        self.assertEqual(state['result'], 'blocked', state)
        self.assertFalse(state['ack'], state)
        self.assertNotEqual(update.exit_code(), 0)
        self.assertEqual(owner.state()['restores'], 0)

    def test_shutdown_activation_waits_for_takeover_or_cancelled_exit(self):
        owner = self.owner()
        owner.command('suspend')
        waiting = self.launch(activation_timeout=2200)
        time.sleep(0.2)
        self.assertIsNone(waiting.state(), 'A disposing owner must not ACK and lose this launch')
        self.assertIsNone(waiting.process.poll())
        owner.close()
        takeover = waiting.wait_state(lambda value: value['attached'])
        self.assertEqual(takeover['result'], 'primary', takeover)
        waiting.close()

        resumed = self.owner()
        resumed.command('suspend')
        retry = self.launch(activation_timeout=2200)
        time.sleep(0.2)
        self.assertIsNone(retry.state(), 'Disposal must wait until exit is cancelled or the lock is released')
        resumed.command('desktop')
        accepted = retry.wait_state()
        self.assertEqual(accepted['result'], 'activated', accepted)
        self.assertEqual(retry.exit_code(), 0)
        resumed.wait_state(lambda value: value['restores'] == 1)
        self.assert_paused(resumed)


class EvidenceResult(unittest.TextTestResult):
    def startTest(self, test):
        super().startTest(test)
        self.started = time.monotonic()
        self.evidence = getattr(self, 'evidence', [])

    def record(self, test, status, detail=''):
        self.evidence.append({'test': test.id(), 'status': status,
                              'seconds': round(time.monotonic() - self.started, 3), 'detail': detail})

    def addSuccess(self, test):
        super().addSuccess(test)
        self.record(test, 'passed')

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.record(test, 'failed', self._exc_info_to_string(err, test))

    def addError(self, test, err):
        super().addError(test, err)
        # setUpClass errors have no startTest invocation.
        if not hasattr(self, 'started'):
            self.started = time.monotonic()
            self.evidence = []
        self.record(test, 'error', self._exc_info_to_string(err, test))

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.record(test, 'skipped', reason)


def main():
    global REQUESTED_CXX, FORCE_MSVC
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument('--cxx', help='LLVM-MinGW clang++ path (also accepts CXX)')
    selection.add_argument('--msvc', action='store_true', help='Require the Visual Studio x64 C++ toolchain')
    parser.add_argument('--report', type=Path, help='Write native execution evidence JSON')
    options = parser.parse_args()
    REQUESTED_CXX = options.cxx or REQUESTED_CXX
    FORCE_MSVC = options.msvc
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(WindowsSingleInstanceNativeTests)
    result = unittest.TextTestRunner(verbosity=2, resultclass=EvidenceResult).run(suite)
    if options.report:
        options.report.parent.mkdir(parents=True, exist_ok=True)
        options.report.write_text(json.dumps({
            'timestamp': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'sourceCommit': os.environ.get('GITHUB_SHA'),
            'workflowRun': os.environ.get('GITHUB_RUN_ID'),
            'compiler': COMPILER, 'nativeExecuted': result.testsRun > 0 and not result.skipped,
            'successful': result.wasSuccessful(), 'testsRun': result.testsRun,
            'cases': getattr(result, 'evidence', []),
            'isolation': 'Synthetic appid, PE brand, executable name, windows, processes and temporary files only',
        }, ensure_ascii=False, indent=2), encoding='utf-8')
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    raise SystemExit(main())
