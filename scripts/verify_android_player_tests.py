import argparse
import json
import os
from pathlib import Path
import re
import xml.etree.ElementTree as ET

repository = 'qq294716498/HongguoTV-Phone-TV-NoAds'
required_cases = {
    'io.flutter.plugins.videoplayer.PlaybackQueueTest': {
        'stageAppendsOnlyOneItemWithoutStoppingOrPreparingPlayer',
        'actualNativeTransitionEmitsIdentityAndTrimsPrevious',
        'manualAdvanceIsIdempotentAndRetainsPausedIntent',
        'suspendCancelsOnlyFutureAndBlocksLateStageUntilResumed',
        'clearRacingNativeSelectionPromotesInsteadOfRemovingCurrent',
        'invalidOrEndedCurrentRejectsAndReleasesPreparedSource',
        'sourceFailureUsesEventItemIdentityAndStaleFailureCannotPoisonReplacement',
        'activationTimeoutFailsOnlyItsGenerationAndDisposalIgnoresLateEvents',
    },
    'io.flutter.plugins.videoplayer.PreparedPlaybackIntegrationTest': {
        'realManagerTransfersLoadedPeriodAndRemovingPreloadKeepsPlaybackAlive',
        'preparedQueueNaturallyAdvancesOnePlayerWithoutAnIntermediateEndOrSecondRenderer',
        'preparedQueueKeepsFiveEpisodesBeyondTwoSecondsBeforeEachNaturalHandoff',
        'queuePauseDropsOnlyCandidateAndManualAdvanceRetainsPause',
    },
    'io.flutter.plugins.videoplayer.PlaybackDiagnosticsTest': {
        'snapshotReadsNativeSpeedAndAudioStateWithoutChangingPlayback',
        'audioUnderrunsKeepLifetimeCountsAndIdentifyOldMediaEvents',
        'lateDecoderAndErrorsCannotPoisonCurrentMediaOrExposeMessages',
        'lateVideoDisableKeepsTheActiveDecoderAndIsCountedOnce',
        'absentMimeAndUnboundedMetadataRemainSafeToReport',
        'durationRefreshesAfterInitiallyUnknownTimeline',
        'countersSurviveDecoderRestartWithoutDoubleCountingSnapshots',
    },
}


def summarize(results, version, build, commit, workflow_run):
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('Android player tests need the exact source commit')
    if not re.fullmatch(r'https://github\.com/' + re.escape(repository) + r'/actions/runs/\d+', workflow_run):
        raise ValueError('Android player tests need the exact workflow run')
    suites = {}
    for path in sorted(results.glob('TEST-*.xml')):
        suite = ET.parse(path).getroot()
        name = suite.attrib.get('name', '')
        if suite.tag != 'testsuite' or not name or name in suites:
            raise ValueError('Invalid or duplicate Android test suite')
        cases = suite.findall('testcase')
        names = [case.attrib.get('name', '') for case in cases]
        if not all(names) or len(set(names)) != len(names):
            raise ValueError('Invalid or duplicate Android test cases')
        if int(suite.attrib.get('tests', '-1')) != len(cases):
            raise ValueError('Android test case count does not match XML')
        if any(int(suite.attrib.get(key, '0')) for key in ['failures', 'errors', 'skipped']):
            raise ValueError('Android player tests have failures, errors or skipped cases')
        if any(case.find(tag) is not None for case in cases for tag in ['failure', 'error', 'skipped']):
            raise ValueError('Android player testcase did not pass')
        suites[name] = names
    if len(suites) < 20 or sum(map(len, suites.values())) < 161:
        raise ValueError('Complete Android player regression reports are missing')
    for name, expected in required_cases.items():
        if not expected.issubset(suites.get(name, [])):
            raise ValueError('Required Android player regression is missing: ' + name)
    return {
        'ok': True,
        'version': version,
        'build': build,
        'sourceCommit': commit,
        'workflowRun': workflow_run,
        'testCount': sum(map(len, suites.values())),
        'suiteCount': len(suites),
        'failures': 0,
        'errors': 0,
        'skipped': 0,
        'requiredCases': {name: sorted(cases) for name, cases in required_cases.items()},
        'suites': suites,
        'scope': 'Java 21 JVM / Robolectric and Media3 synthetic renderers; no physical MediaCodec, display or audio continuity claim',
        'realDevicePlaybackVerified': False,
    }


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument('--results', type=Path, default=root / 'build/video_player_android/test-results/testDebugUnitTest')
    parser.add_argument('--report', type=Path, default=root / 'dist/android/Android-player-tests.json')
    options = parser.parse_args()
    version, build = re.search(r'^version:\s*(\S+)', (root / 'pubspec.yaml').read_text(), re.M).group(1).split('+')
    report = summarize(options.results, version, int(build), os.environ['GITHUB_SHA'],
                       f'https://github.com/{repository}/actions/runs/{os.environ["GITHUB_RUN_ID"]}')
    options.report.parent.mkdir(parents=True, exist_ok=True)
    options.report.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(f'Android player tests verified: {report["testCount"]} cases, {report["suiteCount"]} suites')


if __name__ == '__main__':
    main()
