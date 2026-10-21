import 'models.dart';

final _numberedEpisodeTitle = RegExp(
  r'^(?:第\s*)?[0-9０-９一二三四五六七八九十百千零〇两]+\s*(?:集|话|話|期)?$',
  caseSensitive: false,
);

String episodeName(Episode episode) {
  final title = episode.title.trim();
  return title.isEmpty || _numberedEpisodeTitle.hasMatch(title)
      ? '第 ${episode.number} 集'
      : title;
}

String episodeProgressLabel(DramaDetail detail, int index) {
  final current = index >= 0 && index < detail.episodes.length
      ? episodeName(detail.episodes[index])
      : '当前集未知';
  final count = detail.episodes.length;
  final total = count == 0
      ? '总集数未知'
      : detail.hasMoreEpisodes || detail.drama.episodes > count
      ? '已载入 $count 集'
      : detail.drama.releaseStatus == 'ongoing'
      ? '已更新 $count 集'
      : '共 $count 集';
  return '$current / $total';
}
