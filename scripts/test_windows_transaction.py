import argparse
import ctypes
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import tempfile
import time
import uuid
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]


def wait_for(predicate, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise TimeoutError('Update condition was not reached')


def records(directory, target):
    target.write_text(''.join(
        f'{hashlib.sha256(file.read_bytes()).hexdigest()}\t{file.relative_to(directory).as_posix()}\n'
        for file in sorted(directory.rglob('*')) if file.is_file()), encoding='utf-8')


def compile_fixtures(directory, cxx='g++.exe'):
    compiler = Path(cxx)
    windres = str(compiler.with_name('windres.exe')) if compiler.is_absolute() else 'windres.exe'
    current_build = int(re.search(r'^version:.*\+(\d+)', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.M).group(1))
    for build in sorted({37, 38, 39, current_build - 1}):
        resource = directory / f'fixture-{build}.o'
        subprocess.run([windres, f'-DTEST_BUILD={build}',
                        str(root / 'windows/updater/test_fixture.rc'), str(resource)], check=True)
        subprocess.run([cxx, '-std=c++17', '-municode', '-static', f'-DTEST_BUILD={build}', '-DNOMINMAX',
                        str(root / 'windows/updater/test_fixture.cpp'), str(resource),
                        str(root / 'windows/runner/single_instance.cpp'), '-ladvapi32', '-lversion', '-luser32',
                        '-o', str(directory / f'fixture-{build}.exe')], check=True)
    subprocess.run([cxx, '-std=c++17', '-municode', '-static', '-O2',
                    '-DNOMINMAX', '-DUNICODE', '-D_UNICODE', '-DHONGGUOTV_UPDATER_TEST',
                    str(root / 'windows/updater/updater.cpp'), str(root / 'windows/runner/single_instance.cpp'),
                    '-lbcrypt', '-lversion', '-ladvapi32', '-luser32',
                    '-o', str(directory / 'updater-faults.exe')], check=True)


def transaction(base, fixtures, mode, real=False):
    base.mkdir()
    nonce = uuid.uuid4().hex
    install = base / 'with spaces 中文'
    stage = base / f'.hongguo-stage-{nonce}'
    backup = base / f'.hongguo-backup-{nonce}'
    support = base / 'support'
    environment = os.environ.copy()
    if mode == 'stop-unconfirmed':
        environment['HONGGUOTV_UPDATER_TEST_STOP_FAILURE'] = '1'
    if real:
        environment['APPDATA'] = str(base / 'appdata')
        environment['LOCALAPPDATA'] = str(base / 'localappdata')
        environment['HONGGUOTV_DISABLE_IMAGES'] = '1'
        Path(environment['APPDATA']).mkdir()
        Path(environment['LOCALAPPDATA']).mkdir()
    install.mkdir()
    stage.mkdir()
    build = int(re.search(r'^version:.*\+(\d+)', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.M).group(1)) if real else 39
    old_build = build - 1 if real else 38
    if real:
        version = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.M).group(1).split('+')[0]
        package = root / 'dist/windows' / f'HongguoTV-{version}-windows-x64.zip'
        with zipfile.ZipFile(package) as archive:
            archive.extractall(stage)
        probe_file = base / 'environment.json'
        probe = subprocess.run([str(stage / 'HongguoTV.exe'), '--update-environment-smoke', str(probe_file)],
                               cwd=base.parent, env=environment, capture_output=True,
                               text=True, errors='replace', timeout=30)
        if probe.returncode != 0 or not probe_file.exists():
            raise RuntimeError(f'Update environment probe failed ({probe.returncode}): {probe.stdout}\n{probe.stderr}')
        measured = json.loads(probe_file.read_text(encoding='utf-8'))
        support = Path(measured['support'])
        stage = Path(measured['executable']).parent
        install = stage.parent / install.name
        backup = stage.parent / backup.name
        print(json.dumps({'case': 'real-client-environment', 'support': str(support),
                          'programDirectory': str(stage.parent), 'build': measured['build']}), flush=True)
    else:
        shutil.copyfile(fixtures / 'fixture-39.exe', stage / 'HongguoTV.exe')
    tx = support / 'windows-updates' / nonce
    tx.mkdir(parents=True)
    shutil.copyfile(fixtures / f'fixture-{old_build}.exe', install / 'HongguoTV.exe')
    if not real:
        (tx / 'test-mode').write_text(mode, encoding='ascii')
    config = support / 'shared_preferences.json'
    original = '{"flutter.localSnapshot.v1":"preserved"}' if not real else '{"flutter.app_origin_notice_acknowledged_v1":true}'
    existing_config = config.read_bytes() if config.exists() else None
    config.write_text(original, encoding='utf-8')
    shutil.copyfile(config, tx / 'preferences-backup.json')
    records(install, tx / 'old-files.tsv')
    records(stage, tx / 'new-files.tsv')
    cached_package = support / 'windows-updates' / 'pending.zip'
    if real:
        shutil.copyfile(package, cached_package)
    helper = tx / 'HongguoTV-updater.exe'
    helper_source = root / 'build/windows/x64/runner/Release/HongguoTV-updater.exe' if real else fixtures / 'updater-faults.exe'
    shutil.copyfile(helper_source, helper)
    parent = subprocess.Popen([str(install / 'HongguoTV.exe'), '--hold', str(tx)], env=environment)
    second = subprocess.Popen([str(install / 'HongguoTV.exe'), '--hold', str(tx)], env=environment) if mode == 'second-instance' else None
    other = None
    plan = tx / 'plan.txt'
    fields = {'root': str(install), 'stage': str(stage), 'backup': str(backup),
              'nonce': nonce, 'pid': parent.pid, 'build': build, 'oldBuild': old_build,
              'version': version if real else '0.1.14', 'oldVersion': '0.1.14', 'config': str(config)}
    if mode == 'version':
        fields['build'] = 40
    if mode == 'semantic':
        fields['version'] = '0.1.15'
    plan.write_text('\n'.join(f'{key}={value}' for key, value in fields.items()), encoding='utf-8')
    handle = None
    cleanup_handle = None
    restarted = None
    child_pids = []
    cleanup_result = None
    process = None
    try:
        if real:
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.CreateFileW.restype = ctypes.c_void_p
            kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong,
                                          ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
            cleanup_handle = kernel.CreateFileW(str(tx / 'old-files.tsv'), 0x80000000, 1, None, 3, 0, None)
            if cleanup_handle in [None, ctypes.c_void_p(-1).value]:
                raise RuntimeError('Cannot create cleanup retry fixture')
        if mode == 'tamper':
            with (stage / 'HongguoTV.exe').open('ab') as stream:
                stream.write(b'tamper')
        if mode == 'architecture':
            executable = stage / 'HongguoTV.exe'
            content = bytearray(executable.read_bytes())
            offset = int.from_bytes(content[60:64], 'little')
            content[offset + 4:offset + 6] = bytes.fromhex('4c01')
            executable.write_bytes(content)
            records(stage, tx / 'new-files.tsv')
        if mode == 'unowned':
            (install / 'personal-file.txt').write_text('preserve this file')
        if mode == 'junction':
            target = base / 'external'
            target.mkdir()
            (target / 'personal-file.txt').write_text('preserve this file')
            subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(stage / 'link'), str(target)],
                           check=True, capture_output=True)
        if mode == 'busy':
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.CreateFileW.restype = ctypes.c_void_p
            kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_ulong, ctypes.c_ulong,
                                          ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
            handle = kernel.CreateFileW(str(install / 'HongguoTV.exe'), 0x80000000, 1, None, 3, 0, None)
            if handle in [None, ctypes.c_void_p(-1).value]:
                raise RuntimeError('Cannot create busy file fixture')
        if mode == 'cancel-before-ready':
            (tx / 'cancel.txt').write_text(nonce, encoding='ascii')
        try:
            process = subprocess.Popen([str(helper), str(plan)], env=environment, cwd=tx)
        except OSError as failure:
            diagnostic = {'case': mode, 'ok': False, 'phase': 'launch-helper',
                          'executable': str(helper.resolve()), 'plan': str(plan.resolve()),
                          'cwd': str(tx.resolve()), 'winerror': getattr(failure, 'winerror', None),
                          'error': str(failure), 'helperStarted': False,
                          'synthetic': not real}
            try:
                diagnostic['helperSha256'] = hashlib.sha256(helper.read_bytes()).hexdigest()
            except OSError as read_failure:
                diagnostic['helperReadError'] = str(read_failure)
            print(json.dumps(diagnostic, ensure_ascii=True), flush=True)
            report = root / 'dist/windows/Windows-update-transaction-launch-failure.json'
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text(json.dumps(diagnostic, ensure_ascii=True, indent=2) + '\n', encoding='utf-8')
            raise
        wait_for(lambda: (tx / 'ready.txt').exists() or (tx / 'status.txt').exists())
        if (tx / 'ready.txt').exists():
            if mode == 'cancel-after-ready':
                (tx / 'cancel.txt').write_text(nonce, encoding='ascii')
            else:
                if mode != 'no-handoff':
                    (tx / 'commit.txt').write_text(nonce, encoding='ascii')
                (tx / 'stop-old').touch()
                parent.wait(timeout=10)
                if real:
                    (tx / 'stop-old').unlink(missing_ok=True)
                if mode == 'cross-directory-client':
                    other_install = base / 'other-installation'
                    other_install.mkdir()
                    other_executable = other_install / 'HongguoTV-transaction-fixture.exe'
                    shutil.copyfile(fixtures / 'fixture-39.exe', other_executable)
                    other = subprocess.Popen([str(other_executable), '--hold-client', str(tx)], env=environment)
                    wait_for(lambda: (tx / 'other-client-ready').exists())
        code = process.wait(timeout=90)
        status = (tx / 'status.txt').read_text(encoding='utf-8')
        if mode == 'success':
            assert code == 0 and status.startswith('complete'), status
            assert install.is_dir()
            assert config.exists()
            if not real:
                assert backup.is_dir()
                wait_for(lambda: (tx / 'child-39').exists())
                assert config.read_text(encoding='utf-8') == original
            else:
                pid_file = tx / 'started-pids.txt'
                assert pid_file.exists(), 'Native helper did not record the started client'
                child_pids = pid_file.read_text().splitlines()
                phase_file = tx / f'startup-{build}.json'
                if phase_file.exists():
                    phase = json.loads(phase_file.read_text(encoding='utf-8'))
                    assert phase['phase'] == 'acknowledged' and phase['nonce'] == nonce, phase
                receipt = tx / 'cleanup-receipt.json'
                wait_for(lambda: receipt.exists() and json.loads(receipt.read_text(encoding='utf-8'))['phase'] == 'finalizing', seconds=40)
                assert not backup.exists() and not stage.exists() and not cached_package.exists()
                assert not (tx / 'HongguoTV-updater.exe').exists()
                assert not plan.exists() and (tx / 'old-files.tsv').exists()
                kernel.CloseHandle.argtypes = [ctypes.c_void_p]
                kernel.CloseHandle(cleanup_handle)
                cleanup_handle = None
                for child_pid in child_pids:
                    subprocess.run(['taskkill', '/F', '/PID', child_pid], check=True, capture_output=True)
                restarted = subprocess.Popen([str(install / 'HongguoTV.exe')], env=environment, cwd=install)
                def cleanup_finished():
                    try:
                        result = json.loads((support / 'windows-update-cleanup.json').read_text(encoding='utf-8'))
                        return not tx.exists() and result.get('complete') is True and result.get('nonce') == nonce
                    except (OSError, ValueError):
                        return False
                wait_for(cleanup_finished, seconds=40)
                cleanup = json.loads((support / 'windows-update-cleanup.json').read_text(encoding='utf-8'))
                assert cleanup['complete'] is True and cleanup['nonce'] == nonce, cleanup
                assert not backup.exists() and not stage.exists() and not cached_package.exists()
                cleanup_result = {'case': 'real-client-cleanup-retry', 'ok': True,
                                  'build': build, 'oldBuild': old_build, 'cleanupVerified': True,
                                  'backupRemoved': True, 'downloadRemoved': True,
                                  'transactionRemoved': True, 'retryAfterRestart': True,
                                  'installationDirectoryPreserved': str(install),
                                  'configurationPreserved': True}
        elif mode == 'stop-unconfirmed':
            assert code == 1 and 'exit unconfirmed; rollback withheld' in status, status
            assert backup.is_dir() and install.is_dir() and not stage.exists()
            assert config.read_text(encoding='utf-8') == 'new-config-awaiting-ack'
            assert (tx / 'preferences-backup.json').read_text(encoding='utf-8') == original
            assert not (tx / 'child-38').exists()
            events = [json.loads(line) for line in (tx / 'helper-diagnostics.jsonl').read_text(encoding='utf-8').splitlines()]
            assert any(event['event'] == 'rollback-withheld' for event in events)
            assert not any(event['phase'] == 'rollback-directories' for event in events)
        elif mode == 'cross-directory-client':
            assert code == 1 and 'rolled back' in status and 'configuration recovery withheld' in status, status
            assert config.read_text(encoding='utf-8') == 'active-other-client-config'
            assert (tx / 'preferences-backup.json').read_text(encoding='utf-8') == original
            assert (tx / 'update-child-refused').read_text() == 'blocked'
            assert not (tx / 'ack.txt').exists() and not (tx / 'child-38').exists()
            assert other.poll() is None
            events = [json.loads(line) for line in (tx / 'helper-diagnostics.jsonl').read_text(encoding='utf-8').splitlines()]
            assert any(event['event'] == 'configuration-recovery-withheld' for event in events)
        elif mode in ['crash', 'hang']:
            assert code == 1 and 'rolled back' in status, status
            wait_for(lambda: (tx / 'child-38').exists())
            assert config.read_text(encoding='utf-8') == original
            assert hashlib.sha256((install / 'HongguoTV.exe').read_bytes()).digest() == hashlib.sha256((fixtures / 'fixture-38.exe').read_bytes()).digest()
        else:
            assert code == 1 and status.startswith('failed') and not backup.exists(), status
            if mode in ['cancel-before-ready', 'cancel-after-ready']:
                assert 'cancelled before directory activation' in status, status
                assert parent.poll() is None and stage.is_dir()
            if mode == 'no-handoff':
                assert 'without update handoff authorization' in status, status
            if mode == 'busy':
                assert 'phase=backup-current-directory' in status and 'Win32=' in status, status
                events = [json.loads(line) for line in (tx / 'helper-diagnostics.jsonl').read_text(encoding='utf-8').splitlines()]
                failures = [event for event in events if event['event'] == 'MoveFileExW-failure']
                assert failures and all(int(event['win32Error']) != 0 and event['from'] == str(install) and event['to'] == str(backup) for event in failures)
            if mode == 'unowned':
                assert (install / 'personal-file.txt').read_text() == 'preserve this file'
        if real:
            assert json.loads(config.read_text(encoding='utf-8'))['flutter.app_origin_notice_acknowledged_v1'] is True
        return {'case': 'real-client-startup-ack' if real else mode, 'ok': True, 'status': status,
                'configurationPreserved': mode != 'stop-unconfirmed',
                'configurationBackupPreserved': not real, 'architecture': 'x64',
                'build': build, 'oldBuild': old_build, 'startupAcknowledged': real,
                **({'cleanup': cleanup_result} if real else {})}
    except BaseException:
        if real:
            diagnostic = {'case': 'real-client-startup-ack', 'ok': False,
                          'files': {}}
            for name in ['status.txt', f'startup-{build}.json', 'startup-processes.log']:
                file = tx / name
                if file.exists():
                    diagnostic['files'][name] = file.read_text(encoding='utf-8', errors='replace')[-16000:]
            (root / 'dist/windows/Windows-update-failure.json').write_text(json.dumps(diagnostic, indent=2) + '\n', encoding='utf-8')
            print(json.dumps(diagnostic, ensure_ascii=True), flush=True)
        raise
    finally:
        if not real and tx.exists():
            (tx / 'stop-old').touch()
            (tx / 'stop-new').touch()
            (tx / 'stop-other-client').touch()
        if parent.poll() is None:
            parent.terminate()
            parent.wait(timeout=5)
        if second:
            second.wait(timeout=5)
        if other:
            other.wait(timeout=5)
        if process and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        if handle:
            kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            kernel.CloseHandle(handle)
        if cleanup_handle:
            kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            kernel.CloseHandle(cleanup_handle)
        if restarted and restarted.poll() is None:
            restarted.terminate()
            restarted.wait(timeout=10)
        if real or mode == 'stop-unconfirmed':
            pid_file = tx / 'started-pids.txt'
            if pid_file.exists():
                for child_pid in pid_file.read_text().splitlines():
                    subprocess.run(['taskkill', '/F', '/PID', child_pid], capture_output=True)
            for child_pid in child_pids:
                subprocess.run(['taskkill', '/F', '/PID', child_pid], capture_output=True)
        if real:
            if existing_config is not None:
                config.write_bytes(existing_config)
            else:
                config.unlink(missing_ok=True)
        time.sleep(0.5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cxx', default='g++.exe')
    parser.add_argument('--synthetic-only', action='store_true')
    args = parser.parse_args()
    if platform.system() != 'Windows':
        raise SystemExit('Windows runner required')
    results = []
    with tempfile.TemporaryDirectory(prefix='hongguo-update-') as temporary:
        base = Path(temporary)
        compile_fixtures(base, args.cxx)
        for mode in ['success', 'crash', 'hang', 'busy', 'tamper', 'version', 'semantic', 'architecture', 'unowned', 'junction', 'second-instance', 'cancel-before-ready', 'cancel-after-ready', 'no-handoff', 'stop-unconfirmed', 'cross-directory-client']:
            results.append(transaction(base / mode, base, mode))
            print(json.dumps(results[-1]))
        if not args.synthetic_only:
            results.append(transaction(base / 'real', base, 'success', real=True))
            print(json.dumps(results[-1]))
            results.append(results[-1].pop('cleanup'))
            print(json.dumps(results[-1]))
    report = root / 'dist/windows/Windows-update-transaction.json'
    identity = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.M).group(1).split('+')
    report.write_text(json.dumps({'ok': True, 'version': identity[0], 'build': int(identity[1]), 'cases': results, 'signed': False,
                                 'elevated': False, 'publicReleaseTested': False}, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
