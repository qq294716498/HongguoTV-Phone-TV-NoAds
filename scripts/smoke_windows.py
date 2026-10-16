import json
import os
import platform
import re
import subprocess
import tempfile
import zipfile
import ctypes
import time
from pathlib import Path

root = Path(__file__).resolve().parents[1]


def native_desktop(process, report):
    user = ctypes.WinDLL('user32', use_last_error=True)
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    user.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
    user.PostMessageW.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_ssize_t]
    user.EnumWindows.argtypes = [callback_type, ctypes.c_void_p]
    def wait(predicate):
        deadline = time.monotonic() + 100
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f'Desktop smoke process exited before native actions ({process.returncode})')
            try:
                data = json.loads(report.read_text(encoding='utf-8'))
                if predicate(data):
                    return
            except (FileNotFoundError, json.JSONDecodeError):
                pass
            time.sleep(0.1)
        raise TimeoutError('Native desktop action timed out')
    wait(lambda data: data.get('desktopReady') is True)
    windows = []
    @callback_type
    def collect(window, _):
        pid = ctypes.c_ulong()
        user.GetWindowThreadProcessId(window, ctypes.byref(pid))
        if pid.value == process.pid:
            windows.append(window)
        return True
    user.EnumWindows(collect, None)
    user.GetClassNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
    def is_flutter(window):
        name = ctypes.create_unicode_buffer(256)
        user.GetClassNameW(window, name, len(name))
        return name.value == 'FLUTTER_RUNNER_WIN32_WINDOW'
    window = next(window for window in windows if is_flutter(window))
    user.PostMessageW(window, 0x0010, 0, 0)
    wait(lambda data: data.get('trayKeepsPlaying') is True)
    user.PostMessageW(window, 0x0111, 41002, 0)
    wait(lambda data: data.get('nativeTrayToggles') == 1 and data.get('playing') is False)
    user.PostMessageW(window, 0x0111, 41002, 0)
    wait(lambda data: data.get('nativeTrayToggles') == 2 and data.get('playing') is True)
    user.PostMessageW(window, 0x0111, 41001, 0)
    wait(lambda data: data.get('nativeTrayRestored') is True)
    user.PostMessageW(window, 0x0111, 41003, 0)


def main():
    if platform.system() != 'Windows':
        raise SystemExit('此检查需要 Windows。')
    version = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(encoding='utf-8'), re.MULTILINE).group(1).split('+')[0]
    package = root / 'dist/windows' / f'HongguoTV-{version}-windows-x64.zip'
    output = root / 'dist/windows/Windows-smoke.json'
    with tempfile.TemporaryDirectory(prefix='hongguotv-smoke-') as temporary:
        directory = Path(temporary) / 'with spaces 中文'
        directory.mkdir()
        with zipfile.ZipFile(package) as archive:
            archive.extractall(directory)
        report = directory / 'result.json'
        environment = os.environ.copy()
        for name in list(environment):
            if name.startswith(('JAVA_HOME', 'JDK_HOME')):
                environment.pop(name)
        for name in ['APPDATA', 'LOCALAPPDATA']:
            environment[name] = str(Path(temporary) / name)
            Path(environment[name]).mkdir()
        environment['PATH'] = os.pathsep.join([
            str(directory), str(Path(os.environ['SystemRoot']) / 'System32'),
            os.environ['SystemRoot'],
        ])
        try:
            process = subprocess.Popen([str(directory / 'HongguoTV.exe'), '--package-smoke',
                                      str(report), str(directory / 'fixture.mp4')],
                                     cwd=Path(temporary), env=environment,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors='replace')
            try:
                native_desktop(process, report)
                stdout, stderr = process.communicate(timeout=30)
            except BaseException:
                process.kill()
                stdout, stderr = process.communicate(timeout=10)
                print(stdout)
                print(stderr)
                raise
            print(stdout)
            print(stderr)
            evidence = json.loads(report.read_text(encoding='utf-8'))
            evidence['processExitCode'] = process.returncode
            evidence['cleanPath'] = True
            evidence['javaEnvironmentRemoved'] = True
            evidence['nonAsciiPath'] = True
            evidence['differentWorkingDirectory'] = True
            output.write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
            print(json.dumps(evidence, ensure_ascii=True))
            if process.returncode != 0 or evidence.get('ok') is not True:
                raise SystemExit('Windows 包启动验收未通过。')
            startup_report = directory / 'startup.json'
            startup = subprocess.run([str(directory / 'HongguoTV.exe'), '--startup-smoke', str(startup_report)],
                                     cwd=Path(temporary), env=environment, capture_output=True,
                                     text=True, errors='replace', timeout=60)
            print(startup.stdout)
            print(startup.stderr)
            if startup.returncode != 0:
                detail = startup_report.read_text(encoding='utf-8') if startup_report.exists() else 'no startup report'
                raise RuntimeError(f'Normal application startup failed ({startup.returncode}): {detail}')
            ui = json.loads(startup_report.read_text(encoding='utf-8'))
            if ui.get('ok') is not True or ui.get('normalAppStartup') is not True:
                raise RuntimeError('Application bootstrap did not complete')
            evidence.update(normalAppStartup=True, remoteImagesDisabled=ui['remoteImagesDisabled'])
            output.write_text(json.dumps(evidence, indent=2) + '\n', encoding='utf-8')
            print(json.dumps(evidence))
        except BaseException:
            if report.exists() and not output.exists():
                output.write_bytes(report.read_bytes())
            raise


if __name__ == '__main__':
    main()
