import json
from pathlib import Path
import tempfile
import unittest

from verify_macos_checks import summarize


class MacOSChecksTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.tests = self.directory / 'flutter-tests.jsonl'
        self.analysis = self.directory / 'analysis.log'
        self.analysis.write_text('Analyzing app...\n   info • An actual information diagnostic • lib/main.dart:1:1 • diagnostic\n1 issue found. (ran in 1.0s)\n')
        self.events = []
        for identity in range(1001):
            self.events.extend([
                {'type': 'testStart', 'test': {'id': identity, 'name': f'regression {identity}'}},
                {'type': 'testDone', 'testID': identity, 'result': 'success', 'skipped': identity == 1000, 'hidden': False},
            ])
        self.events.extend([
            {'type': 'testStart', 'test': {'id': 2000, 'name': 'loading /synthetic_test.dart'}},
            {'type': 'testDone', 'testID': 2000, 'result': 'success', 'skipped': False, 'hidden': True},
            {'type': 'done', 'success': True},
        ])

    def report(self, events=None, commit='a' * 40, run='123'):
        self.tests.write_text(''.join(json.dumps(event) + '\n' for event in (self.events if events is None else events)))
        return summarize(self.tests, self.analysis, '0.1.46', 71, commit, run)

    def test_actual_counts_exclude_loading_and_bind_release_identity(self):
        value = self.report()
        self.assertEqual((value['flutterTestsPassed'], value['flutterTestsSkipped'], value['analysisInfos']), (1000, 1, 1))
        self.assertEqual((value['version'], value['build'], value['sourceCommit'], value['workflowRun']), ('0.1.46', 71, 'a' * 40, '123'))
        self.assertIs(value['allSources'], False)

    def test_flutter_daemon_started_process_and_shell_diagnostics_do_not_count_as_tests(self):
        daemon = [{'event': 'test.startedProcess', 'params': {'vmServiceUri': None}}]
        value = self.report([daemon, *self.events[:2], daemon, *self.events[2:]])
        self.assertEqual((value['flutterTestsPassed'], value['flutterTestsSkipped'], value['ignoredDaemonEvents']), (1000, 1, 2))
        self.tests.write_text('Shell: Windows cleanup retry result=true\nShell: {"nonce":"synthetic"}\n' + self.tests.read_text())
        value = summarize(self.tests, self.analysis, '0.1.46', 71, 'a' * 40, '123')
        self.assertEqual((value['flutterTestsPassed'], value['ignoredDaemonEvents'], value['ignoredShellLines']), (1000, 2, 2))

    def test_arbitrary_arrays_untyped_events_and_malformed_reporter_data_are_rejected(self):
        for event in [[], [{'event': 'other', 'params': {'vmServiceUri': None}}],
                      [{'event': 'test.startedProcess', 'params': {}}],
                      [{'event': 'test.startedProcess', 'params': {'vmServiceUri': None}, 'type': 'error'}],
                      [{'type': 'error', 'error': 'failure'}], {}, None, 123, 'text',
                      {'type': 'unknown'}, {'type': 'testStart', 'test': []},
                      {'type': 'testDone', 'testID': 0, 'result': 'success', 'hidden': False, 'skipped': 'false'}]:
            with self.subTest(event=event), self.assertRaises(ValueError):
                self.report([*self.events, event])
        self.report()
        self.tests.write_text(self.tests.read_text() + '{"type":"testDone"\n')
        with self.assertRaises(json.JSONDecodeError):
            summarize(self.tests, self.analysis, '0.1.46', 71, 'a' * 40, '123')

    def test_incomplete_failed_duplicate_and_truncated_runs_are_rejected(self):
        variants = [self.events[:-1], self.events + [{'type': 'done', 'success': True}],
                    [*self.events[:-1], {'type': 'done', 'success': False}],
                    self.events[2:], [*self.events, self.events[1]],
                    [*self.events, {'type': 'error', 'error': 'real failure'}],
                    [self.events[0], {**self.events[1], 'result': 'failure'}, *self.events[2:]]]
        for events in variants:
            with self.subTest(last=events[-1]), self.assertRaises(ValueError):
                self.report(events)

    def test_hidden_tests_cannot_satisfy_complete_regression_floor(self):
        events = [dict(event, hidden=True) if event['type'] == 'testDone' and event['testID'] == 0 else event for event in self.events]
        with self.assertRaisesRegex(ValueError, '1000'):
            self.report(events)

    def test_diagnostics_require_a_consistent_complete_summary_and_no_warnings(self):
        for analysis in ['', 'Analyzing app...\n', '2 issues found.\n',
                         'warning • real warning • lib/a.dart:1:1 • warning\n1 issue found.\n',
                         'error • real error • lib/a.dart:1:1 • error\n1 issue found.\n',
                         'info • real info • lib/a.dart:1:1 • info\nNo issues found!\n']:
            with self.subTest(analysis=analysis), self.assertRaises(ValueError):
                self.analysis.write_text(analysis)
                self.report()

    def test_clean_analysis_and_exact_workflow_identity_are_required(self):
        self.analysis.write_text('Analyzing app...\nNo issues found! (ran in 1.0s)\n')
        self.assertEqual(self.report()['analysisInfos'], 0)
        for commit, run in [('branch', '123'), ('a' * 40, ''), ('a' * 40, '0')]:
            with self.subTest(commit=commit, run=run), self.assertRaises(ValueError):
                self.report(commit=commit, run=run)


if __name__ == '__main__':
    unittest.main()
