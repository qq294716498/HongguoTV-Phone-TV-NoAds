import 'package:duanju_app/episode_label.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

DramaDetail season({
  int count = 24,
  int declared = 24,
  String status = 'finished',
  bool partial = false,
}) => DramaDetail(
  Drama(
    id: 'season-only',
    source: 'hongguo',
    title: '本季',
    episodes: declared,
    releaseStatus: status,
  ),
  List.generate(
    count,
    (i) => Episode({
      'id': '$i',
      'title': '第${i + 1}集',
      'currentEpisode': i + 1,
    }, i + 1),
  ),
  hasMoreEpisodes: partial,
);

void main() {
  test(
    'current season counts entries rather than episode number or series total',
    () {
      expect(episodeProgressLabel(season(), 2), '第 3 集 / 共 24 集');
      final sparse = DramaDetail(season().drama, [
        Episode({'title': '第100集', 'currentEpisode': 100}, 1),
      ]);
      expect(episodeProgressLabel(sparse, 0), '第 100 集 / 已载入 1 集');
      expect(
        episodeProgressLabel(season(count: 12, declared: 12), 0),
        '第 1 集 / 共 12 集',
      );
    },
  );
  test(
    'ongoing, incomplete and unavailable lists never claim a final or zero total',
    () {
      expect(
        episodeProgressLabel(
          season(count: 3, declared: 3, status: 'ongoing'),
          2,
        ),
        '第 3 集 / 已更新 3 集',
      );
      expect(
        episodeProgressLabel(season(count: 3, partial: true), 2),
        '第 3 集 / 已载入 3 集',
      );
      expect(episodeProgressLabel(season(count: 0), 0), '当前集未知 / 总集数未知');
      final parsed = DramaDetail.fromJson({
        'drama': {'id': 'x'},
        'chapters': [
          {'id': 'a'},
        ],
        'episodesComplete': false,
      });
      expect(episodeProgressLabel(parsed, 0), '第 1 集 / 已载入 1 集');
    },
  );
  test(
    'special titles remain recognizable and numeric formats stay consistent',
    () {
      expect(episodeName(Episode({'title': '番外 · 团圆'}, 25)), '番外 · 团圆');
      expect(episodeName(Episode({'title': '特别篇 上'}, 26)), '特别篇 上');
      expect(
        episodeName(Episode({'title': '第十二话', 'currentEpisode': 12}, 1)),
        '第 12 集',
      );
      expect(episodeName(Episode({'title': '12'}, 12)), '第 12 集');
    },
  );
}
