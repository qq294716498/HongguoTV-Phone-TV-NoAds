import argparse
import json
import os
from pathlib import Path
import re


def summarize(tests, analysis, version, build, commit, workflow_run):
    if not re.fullmatch(r'[0-9a-f]{40}', commit) or not re.fullmatch(r'[1-9][0-9]*', str(workflow_run)):
        raise ValueError('macOS checks require the exact source commit and workflow run')
    started, completed = {}, {}
    done = []
    ignored_daemon_events = ignored_shell_lines = 0
    for line in tests.read_text(encoding='utf-8').splitlines():
        if not line.strip():
            continue
        if line.startswith('Shell: '):
            ignored_shell_lines += 1
            continue
        event = json.loads(line)
        if isinstance(event, list):
            if event != [{'event': 'test.startedProcess', 'params': {'vmServiceUri': None}}]:
                raise ValueError('Unexpected Flutter daemon event array')
            ignored_daemon_events += 1
            continue
        if not isinstance(event, dict) or event.get('type') not in (
                'start', 'allSuites', 'suite', 'debug', 'group', 'testStart', 'print', 'error', 'testDone', 'done'):
            raise ValueError('Invalid package:test reporter event')
        kind = event.get('type')
        if kind == 'testStart':
            test = event.get('test')
            if not isinstance(test, dict):
                raise ValueError('Invalid Flutter test identity')
            identity = test.get('id')
            if type(identity) is not int or identity < 0 or identity in started or not isinstance(test.get('name'), str):
                raise ValueError('Duplicate or invalid Flutter test identity')
            started[identity] = test
        elif kind == 'testDone':
            identity = event.get('testID')
            if type(identity) is not int or identity not in started or identity in completed or event.get('result') != 'success' or type(event.get('skipped')) is not bool or type(event.get('hidden')) is not bool:
                raise ValueError('Flutter test failed or has an invalid completion')
            completed[identity] = event
        elif kind == 'error':
            raise ValueError('Flutter regression reported an error')
        elif kind == 'done':
            done.append(event)
    if len(done) != 1 or done[0].get('success') is not True or set(started) != set(completed):
        raise ValueError('Complete successful Flutter regression evidence is required')
    visible = [event for identity, event in completed.items()
               if event.get('hidden') is not True and not started[identity]['name'].startswith('loading ')]
    passed = sum(event.get('skipped') is not True for event in visible)
    skipped = sum(event.get('skipped') is True for event in visible)
    if passed < 1000:
        raise ValueError('Complete macOS Flutter regression is missing (fewer than 1000 passed tests)')
    log = analysis.read_text(encoding='utf-8')
    counts = {kind: len(re.findall(r'^\s*' + kind + r'\s+[•-]\s+', log, re.M))
              for kind in ('error', 'warning', 'info')}
    summary = re.findall(r'\b(\d+) issues? found\.', log)
    if 'No issues found!' in log:
        if sum(counts.values()) or summary:
            raise ValueError('Analysis summary disagrees with diagnostics')
    elif len(summary) != 1 or int(summary[0]) != sum(counts.values()):
        raise ValueError('Complete analysis diagnostics and summary are required')
    if counts['error'] or counts['warning']:
        raise ValueError('Analysis errors or warnings block publication')
    return {
        'ok': True, 'version': version, 'build': int(build), 'sourceCommit': commit,
        'workflowRun': str(workflow_run), 'allSources': False,
        'flutterTestsPassed': passed, 'flutterTestsSkipped': skipped,
        'flutterTestsFailed': 0, 'flutterCompletedSuccessfully': True,
        'ignoredDaemonEvents': ignored_daemon_events, 'ignoredShellLines': ignored_shell_lines,
        'analysisErrors': counts['error'], 'analysisWarnings': counts['warning'],
        'analysisInfos': counts['info'],
    }


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument('--tests', type=Path, default=root / 'dist/macos/flutter-tests.jsonl')
    parser.add_argument('--analysis', type=Path, default=root / 'dist/macos/analysis.log')
    parser.add_argument('--report', type=Path, default=root / 'dist/macos/macOS-checks.json')
    options = parser.parse_args()
    version, build = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(), re.M).group(1).split('+')
    report = summarize(options.tests, options.analysis, version, build,
                       os.environ['GITHUB_SHA'], os.environ['GITHUB_RUN_ID'])
    options.report.parent.mkdir(parents=True, exist_ok=True)
    options.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f'macOS checks verified: {report["flutterTestsPassed"]} passed, {report["flutterTestsSkipped"]} skipped')


if __name__ == '__main__':
    main()
