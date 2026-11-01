from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from verify_android_player_tests import required_cases, summarize


class AndroidPlayerReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.results = Path(self.temporary.name)
        self.commit = 'a' * 40
        self.run = 'https://github.com/qq294716498/HongguoTV-Phone-TV-NoAds/actions/runs/123'
        suites = {**required_cases, **{f'synthetic.Suite{index:02}': {f'case{n}' for n in range(8)} for index in range(18)}}
        for name, cases in suites.items():
            suite = ET.Element('testsuite', name=name, tests=str(len(cases)), failures='0', errors='0', skipped='0')
            for case in sorted(cases):
                ET.SubElement(suite, 'testcase', name=case, classname=name)
            ET.ElementTree(suite).write(self.results / f'TEST-{name}.xml')

    def summarize(self):
        return summarize(self.results, '0.1.46', 71, self.commit, self.run)

    def test_complete_passed_reports_keep_exact_identity_and_queue_cases(self):
        report = self.summarize()
        self.assertTrue(report['ok'])
        self.assertEqual(report['testCount'], 156)
        self.assertEqual(report['suiteCount'], 20)
        self.assertEqual(report['sourceCommit'], self.commit)
        self.assertEqual(report['workflowRun'], self.run)
        self.assertFalse(report['realDevicePlaybackVerified'])
        self.assertIn('no physical MediaCodec', report['scope'])

    def test_missing_reports_or_queue_case_cannot_pass(self):
        queue = self.results / 'TEST-io.flutter.plugins.videoplayer.PlaybackQueueTest.xml'
        queue.unlink()
        with self.assertRaises(ValueError):
            self.summarize()

    def test_five_episode_chain_is_required_even_with_complete_total_count(self):
        path = self.results / 'TEST-io.flutter.plugins.videoplayer.PreparedPlaybackIntegrationTest.xml'
        tree = ET.parse(path)
        suite = tree.getroot()
        case = next(case for case in suite.findall('testcase')
                    if case.attrib['name'] == 'preparedQueueKeepsFiveEpisodesBeyondTwoSecondsBeforeEachNaturalHandoff')
        suite.remove(case)
        ET.SubElement(suite, 'testcase', name='syntheticExtraPassingCase', classname=suite.attrib['name'])
        tree.write(path)
        with self.assertRaisesRegex(ValueError, 'Required single-player queue regression is missing'):
            self.summarize()

    def test_failure_error_and_skip_attributes_block(self):
        path = next(self.results.glob('TEST-*.xml'))
        original = path.read_bytes()
        for attribute in ['failures', 'errors', 'skipped']:
            tree = ET.fromstring(original)
            tree.set(attribute, '1')
            ET.ElementTree(tree).write(path)
            with self.subTest(attribute=attribute), self.assertRaises(ValueError):
                self.summarize()
        path.write_bytes(original)

    def test_testcase_failure_cannot_hide_behind_zero_totals(self):
        path = next(self.results.glob('TEST-*.xml'))
        tree = ET.parse(path)
        ET.SubElement(tree.getroot().find('testcase'), 'failure')
        tree.write(path)
        with self.assertRaises(ValueError):
            self.summarize()

    def test_count_mismatch_and_duplicate_cases_block(self):
        path = next(self.results.glob('TEST-*.xml'))
        original = path.read_bytes()
        tree = ET.fromstring(original)
        tree.set('tests', '500')
        ET.ElementTree(tree).write(path)
        with self.assertRaises(ValueError):
            self.summarize()
        tree = ET.fromstring(original)
        case = tree.find('testcase')
        ET.SubElement(tree, 'testcase', **case.attrib)
        tree.set('tests', str(len(tree.findall('testcase'))))
        ET.ElementTree(tree).write(path)
        with self.assertRaises(ValueError):
            self.summarize()

    def test_wrong_identity_or_non_github_run_blocks(self):
        for commit, run in [('unknown', self.run), (self.commit, 'https://example.com/runs/123')]:
            with self.subTest(commit=commit, run=run), self.assertRaises(ValueError):
                summarize(self.results, '0.1.46', 71, commit, run)


if __name__ == '__main__':
    unittest.main()
