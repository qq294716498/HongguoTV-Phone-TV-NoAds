import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import zipfile


approved_commit = 'ca5a75106b2b7c2efb9ec0b180992fdf48bb941d'
approved_run = '41490857169'
approved_job = 125438717527
approved_checks_job = 125433149975
approved_artifact = 13165551336
approved_outer_sha256 = '9da5358d5fd90ec3721ada07679a708230761281dae2e35e235a96a18a98dbbc'
approved_outer_bytes = 100967879
approved_sha256 = '4f443c29fe4d4b22178c76b8ad97b3f9d6002f48ead28865600db2fee33a8026'
approved_bytes = 101241846
package_name = 'HongguoTV-0.1.48-windows-x64.zip'
reader_case = '__main__.WindowsSingleInstanceNativeTests.test_report_publication_recovers_after_reader_lock'
failed_case = '__main__.WindowsSingleInstanceNativeTests.test_shutdown_activation_waits_for_takeover_or_cancelled_exit'
release_only_paths = frozenset({
    'README.md', '.github/workflows/windows-recovery.yml',
    'scripts/publish_windows_stable.py', 'scripts/test_windows_stable_publish.py',
    'scripts/publish_android_stable.py',
    'scripts/reuse_windows_package.py', 'scripts/test_reuse_windows_package.py',
    'scripts/test_windows_single_instance_native.py',
    'scripts/tests/windows_single_instance_harness.cpp',
})
validation_reports = (
    'Windows-validation.json', 'Windows-smoke.json', 'Windows-signature.json',
    'Windows-update-transaction.json', 'Windows-single-instance-native.json',
    'Windows-single-instance-original-reader-lock.json', 'Windows-playback-queue.json',
    'Windows-app-autoplay-chain.json',
)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def git(root, *arguments):
    return subprocess.check_output(['git', *arguments], cwd=root, text=True).strip()


def source_digest(root, commit, name):
    return hashlib.sha256(subprocess.check_output(['git', 'show', f'{commit}:{name}'], cwd=root).replace(b'\r\n', b'\n')).hexdigest()


def source_file_digest(path):
    return hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def validate_reuse_configuration():
    if (not re.fullmatch(r'[0-9a-f]{40}', approved_commit)
            or not re.fullmatch(r'[1-9]\d*', approved_run)
            or not re.fullmatch(r'[0-9a-f]{64}', approved_sha256)
            or not re.fullmatch(r'[0-9a-f]{64}', approved_outer_sha256)):
        raise ValueError('A verified current Windows build must be pinned before reuse')


def validate_source(root):
    validate_reuse_configuration()
    current = git(root, 'rev-parse', 'HEAD')
    if os.environ.get('GITHUB_SHA', current) != current:
        raise ValueError('Validation checkout does not match GITHUB_SHA')
    if git(root, 'merge-base', approved_commit, current) != approved_commit:
        raise ValueError('Validation must descend from the original binary source')
    changed = set(git(root, 'diff', '--name-only', '--no-renames', approved_commit, current, '--').splitlines())
    if changed - release_only_paths:
        raise ValueError('Application or build inputs changed; a fresh compilation is required')
    if git(root, 'status', '--porcelain', '--untracked-files=no'):
        raise ValueError('Tracked source files changed after checkout')
    return current, sorted(changed)


def validate_original_run(run, run_id):
    validate_reuse_configuration()
    if (run_id != approved_run or str(run.get('id')) != approved_run
            or run.get('head_sha') != approved_commit or run.get('run_attempt') != 1
            or run.get('head_branch') != 'release/windows-android-0.1.48-74'
            or run.get('status') != 'completed' or run.get('conclusion') != 'failure'
            or run.get('path') != '.github/workflows/windows-preview.yml'
            or run.get('head_repository', {}).get('full_name') != 'qq294716498/HongguoTV-Phone-TV-NoAds'):
        raise ValueError('Original run is not the pinned Windows build attempt')


def validate_original_jobs(jobs):
    windows = [job for job in jobs if job.get('id') == approved_job]
    checks = [job for job in jobs if job.get('name') == 'checks' and job.get('id') == approved_checks_job]
    if len(windows) != 1 or len(checks) != 1 or checks[0].get('conclusion') != 'success':
        raise ValueError('Original checks and build job identity were not verified')
    job = windows[0]
    steps = job.get('steps', [])
    built = [step for step in steps if step.get('name') == 'Run python scripts/build_windows.py --all-sources']
    failed = [step.get('name') for step in steps if step.get('conclusion') == 'failure']
    if (job.get('name') != 'windows' or job.get('status') != 'completed'
            or job.get('conclusion') != 'failure' or job.get('run_attempt', 1) != 1
            or len(built) != 1 or built[0].get('conclusion') != 'success'
            or failed != ['Verify isolated native single-instance lifecycle with MSVC']):
        raise ValueError('Only the successful build followed by the isolated fixture failure may be reused')


def validate_artifact(value):
    if (value.get('id') != approved_artifact or value.get('name') != 'hongguotv-windows-x64'
            or value.get('expired') is not False or value.get('size_in_bytes') != approved_outer_bytes
            or value.get('digest') != 'sha256:' + approved_outer_sha256
            or str(value.get('workflow_run', {}).get('id')) != approved_run
            or value.get('workflow_run', {}).get('head_sha') != approved_commit):
        raise ValueError('Original artifact identity or digest changed')


def validate_original_failure(value):
    cases = value.get('cases', [])
    failures = [case for case in cases if case.get('status') != 'passed']
    if (value.get('sourceCommit') != approved_commit or str(value.get('workflowRun')) != approved_run
            or value.get('compiler', {}).get('family') != 'MSVC' or value.get('nativeExecuted') is not True
            or value.get('successful') is not False or value.get('testsRun') != 16 or len(cases) != 16
            or len({case.get('test') for case in cases}) != 16 or len(failures) != 1
            or failures[0].get('test') != failed_case or failures[0].get('status') != 'failed'
            or 'takeover = waiting.wait_state' not in failures[0].get('detail', '')
            or "'attached': False" not in failures[0].get('detail', '')):
        raise ValueError('Original failure is not the pinned lost-report fixture failure')


def expected_hashes(root):
    return {
        'originalHarnessSourceSha256': source_digest(root, approved_commit, 'scripts/tests/windows_single_instance_harness.cpp'),
        'validationHarnessSourceSha256': source_file_digest(root / 'scripts/tests/windows_single_instance_harness.cpp'),
        'instanceGuardSourceSha256': source_digest(root, approved_commit, 'windows/runner/single_instance.cpp'),
    }


def validate_reader_lock(value, provenance):
    cases = value.get('cases', [])
    if (value.get('sourceCommit') != provenance['validationSourceCommit']
            or str(value.get('workflowRun')) != provenance['validationWorkflowRun']
            or value.get('compiler', {}).get('family') != 'MSVC' or value.get('nativeExecuted') is not True
            or value.get('successful') is not False or value.get('testsRun') != 1 or len(cases) != 1
            or value.get('sourceHashNormalization') != 'LF'
            or value.get('harnessSourceSha256') != provenance['originalHarnessSourceSha256']
            or value.get('instanceGuardSourceSha256') != provenance['instanceGuardSourceSha256']):
        raise ValueError('The original reader-lock regression did not execute the pinned sources')
    case = cases[0]
    observations = case.get('observations', [])
    if (case.get('test') != reader_case or case.get('status') != 'failed'
            or 'Synthetic fixture condition was not reached before timeout' not in case.get('detail', '')
            or 'updated = owner.wait_state' not in case.get('detail', '')
            or len(observations) != 1
            or observations[0] != {'operation': 'restore-while-report-reader-denies-delete',
                                   'nativeVisible': True, 'publishedVisible': False, 'publishedRestores': 0}):
        raise ValueError('The old failure did not reach the controlled reader lock and publication wait')


def validate_fixed_reader(value, provenance):
    if (value.get('sourceCommit') != provenance['validationSourceCommit']
            or str(value.get('workflowRun')) != provenance['validationWorkflowRun']
            or value.get('sourceHashNormalization') != 'LF'
            or value.get('harnessSourceSha256') != provenance['validationHarnessSourceSha256']
            or value.get('instanceGuardSourceSha256') != provenance['instanceGuardSourceSha256']):
        raise ValueError('Fixed native validation source differs from the recovery source')
    cases = [case for case in value.get('cases', []) if case.get('test') == reader_case]
    if len(cases) != 1 or cases[0].get('status') != 'passed':
        raise ValueError('The fixed reader-lock case did not pass')
    observations = cases[0].get('observations', [])
    if (len(observations) != 2 or observations[0] != {
            'operation': 'restore-while-report-reader-denies-delete', 'nativeVisible': True,
            'publishedVisible': False, 'publishedRestores': 0}
            or observations[1].get('operation') != 'publish-after-reader-release'
            or observations[1].get('reportPublishFailures', 0) < 1
            or observations[1].get('lastReportError') not in [5, 32]):
        raise ValueError('The fixed case did not observe failed publication and recovery')


def read_json(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def check_provenance(root, provenance):
    current, changed = validate_source(root)
    if (provenance.get('binarySourceCommit') != approved_commit
            or provenance.get('binaryWorkflowRun') != approved_run
            or provenance.get('artifactId') != approved_artifact
            or provenance.get('artifactDigest') != approved_outer_sha256
            or provenance.get('packageSha256') != approved_sha256 or provenance.get('packageBytes') != approved_bytes
            or provenance.get('validationSourceCommit') != current
            or provenance.get('validationWorkflowRun') != os.environ.get('GITHUB_RUN_ID')
            or provenance.get('allowedSourceChanges') != changed
            or provenance.get('sourceHashNormalization') != 'LF'
            or any(provenance.get(key) != value for key, value in expected_hashes(root).items())):
        raise ValueError('Recovery provenance does not match this source and workflow run')
    return provenance


def manifest(root, output):
    provenance = check_provenance(root, read_json(output / 'Windows-reuse-provenance.json'))
    if digest(output / package_name) != approved_sha256 or (output / package_name).stat().st_size != approved_bytes:
        raise ValueError('Reused Windows package changed')
    validate_reader_lock(read_json(output / 'Windows-single-instance-original-reader-lock.json'), provenance)
    validate_fixed_reader(read_json(output / 'Windows-single-instance-native.json'), provenance)
    return {'binarySourceCommit': approved_commit, 'validationSourceCommit': provenance['validationSourceCommit'],
            'validationWorkflowRun': provenance['validationWorkflowRun'],
            'packageSha256': approved_sha256,
            'reports': {name: {'sha256': digest(output / name), 'bytes': (output / name).stat().st_size}
                        for name in validation_reports}}


def main():
    root = Path(__file__).resolve().parents[1]
    output = root / 'dist/windows'
    action = 'reuse' if len(sys.argv) == 1 else sys.argv[1]
    if action == 'verify-reader-lock':
        provenance = check_provenance(root, read_json(output / 'Windows-reuse-provenance.json'))
        validate_reader_lock(read_json(output / 'Windows-single-instance-original-reader-lock.json'), provenance)
        return
    if action == 'seal-validation':
        value = manifest(root, output)
        (output / 'Windows-recovery-validation.json').write_text(json.dumps(value, indent=2) + '\n')
        return
    if action != 'reuse':
        raise ValueError('Expected reuse, verify-reader-lock or seal-validation')
    current, changed = validate_source(root)
    run_id = os.environ['REUSE_RUN_ID']
    if run_id != approved_run:
        raise ValueError('Unexpected original build run')
    def github(path):
        return json.loads(subprocess.check_output(['gh', 'api', 'repos/qq294716498/HongguoTV-Phone-TV-NoAds/' + path], text=True))
    validate_original_run(github('actions/runs/' + run_id), run_id)
    validate_original_jobs(github('actions/runs/' + run_id + '/jobs?filter=all&per_page=100')['jobs'])
    validate_artifact(github('actions/artifacts/' + str(approved_artifact)))
    validate_original_failure(read_json(output / 'Windows-single-instance-native.json'))
    package = output / package_name
    if package.stat().st_size != approved_bytes or digest(package) != approved_sha256:
        raise ValueError('Original package checksum or size mismatch')
    checksum = (output / 'SHA256SUMS.txt').read_text(encoding='ascii').strip()
    if checksum != approved_sha256 + '  ' + package_name:
        raise ValueError('Original package checksum manifest differs')
    destination = root / 'build/windows/x64/runner/Release'
    destination.mkdir(parents=True, exist_ok=False)
    with zipfile.ZipFile(package) as archive:
        for item in archive.infolist():
            path = PurePosixPath(item.filename)
            if (path.is_absolute() or '..' in path.parts or '\\' in item.filename or ':' in item.filename
                    or stat.S_ISLNK(item.external_attr >> 16)):
                raise ValueError('Unsafe original package path')
        if archive.testzip() is not None:
            raise ValueError('Original package CRC mismatch')
        archive.extractall(destination)
    dll = destination / 'duanju_core.dll'
    target = root / 'windows/runner/duanju_core.dll'
    shutil.copy2(dll, target)
    if digest(target) != digest(dll):
        raise ValueError('Integration native DLL differs from the reused package')
    shutil.copy2(output / 'Windows-single-instance-native.json', output / 'Windows-single-instance-original-build.json')
    value = {'binarySourceCommit': approved_commit, 'binaryWorkflowRun': approved_run,
             'artifactId': approved_artifact, 'artifactDigest': approved_outer_sha256,
             'packageSha256': approved_sha256, 'packageBytes': approved_bytes,
             'validationSourceCommit': current, 'validationWorkflowRun': os.environ['GITHUB_RUN_ID'],
             'allowedSourceChanges': changed, 'integrationCoreDllSha256': digest(dll),
             'sourceHashNormalization': 'LF',
             **expected_hashes(root)}
    (output / 'Windows-reuse-provenance.json').write_text(json.dumps(value, indent=2) + '\n')
    print(json.dumps(value))


if __name__ == '__main__':
    main()
