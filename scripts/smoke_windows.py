import json
import os
import platform
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]


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
            process = subprocess.run([str(directory / 'HongguoTV.exe'), '--package-smoke',
                                      str(report), str(directory / 'fixture.mp4')],
                                     cwd=Path(temporary), env=environment,
                                     capture_output=True, text=True, errors='replace', timeout=120)
            print(process.stdout)
            print(process.stderr)
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
