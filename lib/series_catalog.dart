import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'hongguo_series.dart';
import 'models.dart';

class SeriesCatalog extends ChangeNotifier {
  SeriesCatalog({
    required this.anchor,
    required this.repository,
    required Iterable<Drama> knownDramas,
    required this.allowed,
  }) {
    for (final drama in [anchor, ...knownDramas]) {
      _candidates.putIfAbsent(drama.id, () => drama);
    }
  }

  final Drama anchor;
  final AppRepository repository;
  final bool Function() allowed;
  final _candidates = <String, Drama>{};
  bool loading = false;
  bool hasMore = true;
  String error = '';
  int _page = 0;
  int _generation = 0;
  bool _disposed = false;

  List<HongguoSeriesEntry> get entries {
    final found = hongguoSeriesEntries(anchor, _candidates.values);
    if (found.isNotEmpty) return found;
    final info = hongguoSeriesInfo(anchor);
    return [
      HongguoSeriesEntry(
        drama: anchor,
        season: info?.season ?? 1,
        unit: info?.unit ?? '季',
      ),
    ];
  }

  String get title => hongguoSeriesInfo(anchor)?.baseTitle ?? anchor.title;
  bool _current(int generation) =>
      !_disposed && generation == _generation && allowed();

  Future<void> load({bool refresh = false}) async {
    if (_disposed || loading || !allowed() || (!refresh && !hasMore)) return;
    if (refresh) {
      _page = 0;
      hasMore = true;
    }
    final generation = ++_generation;
    loading = true;
    error = '';
    notifyListeners();
    try {
      for (var count = 0; count < 5 && hasMore; count++) {
        final page = _page + 1;
        final result = await repository
            .catalog(
              anchor.source,
              query: title.trim(),
              page: page,
              force: page == 1,
            )
            .timeout(const Duration(seconds: 20));
        if (!_current(generation)) return;
        for (final drama in result.items) {
          _candidates[drama.id] = drama;
        }
        _page = page;
        hasMore = result.hasMore;
        if (result.warning.isNotEmpty) {
          error = result.warning;
          break;
        }
        notifyListeners();
      }
    } catch (_) {
      if (_current(generation)) {
        error = '部分季暂时未能加载，请重试';
      }
    } finally {
      if (_current(generation)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  void cancel() {
    _generation++;
    loading = false;
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }
}
