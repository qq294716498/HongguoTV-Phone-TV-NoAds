import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'television_search_field.dart';

class SearchInput extends StatefulWidget {
  const SearchInput({
    super.key,
    required this.controller,
    required this.hint,
    required this.onSearch,
    this.onChanged,
    this.suggestions,
    this.onCancel,
    this.autofocus = false,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onSearch;
  final ValueChanged<String>? onChanged;
  final Future<List<String>> Function(String)? suggestions;
  final VoidCallback? onCancel;
  final bool autofocus;
  @override
  State<SearchInput> createState() => _SearchInputState();
}

class _SearchInputState extends State<SearchInput> {
  final _focus = FocusNode();
  final _optionsController = TextEditingController();
  final _hasText = ValueNotifier<bool>(false);
  late TextEditingValue _lastValue;
  bool _submitting = false;
  int? _activeRequest;
  VoidCallback? _cancelActiveRequest;
  Timer? _timer;
  Completer<Iterable<String>>? _pending;
  int _generation = 0;
  bool _selected = false;
  final _cache = <String, List<String>>{};

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    if (_activeRequest != null) {
      _activeRequest = null;
      final cancel = _cancelActiveRequest;
      _cancelActiveRequest = null;
      cancel?.call();
    }
    _generation++;
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.complete(const []);
    }
  }

  @override
  void initState() {
    super.initState();
    _lastValue = widget.controller.value;
    _hasText.value = _lastValue.text.isNotEmpty;
    widget.controller.addListener(_controllerChanged);
    _focus.addListener(_focusChanged);
  }

  void _syncOptions() {
    final value = widget.controller.value;
    final text =
        !_submitting &&
            _focus.hasFocus &&
            widget.suggestions != null &&
            value.composing.isCollapsed
        ? value.text
        : '';
    if (_optionsController.text != text) {
      _optionsController.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  void _controllerChanged() {
    final previous = _lastValue;
    final value = widget.controller.value;
    _lastValue = value;
    _hasText.value = value.text.isNotEmpty;
    _syncOptions();
    if (!_submitting &&
        !previous.composing.isCollapsed &&
        value.composing.isCollapsed &&
        previous.text == value.text) {
      widget.onChanged?.call(value.text);
    }
  }

  void _focusChanged() {
    if (!_focus.hasFocus) _cancel();
    _syncOptions();
  }

  @override
  void didUpdateWidget(SearchInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller != oldWidget.controller ||
        widget.suggestions != oldWidget.suggestions) {
      _cancel();
      _cache.clear();
      oldWidget.controller.removeListener(_controllerChanged);
      _lastValue = widget.controller.value;
      _hasText.value = _lastValue.text.isNotEmpty;
      widget.controller.addListener(_controllerChanged);
      _optionsController.clear();
      _syncOptions();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_controllerChanged);
    _focus.removeListener(_focusChanged);
    _cancel();
    _optionsController.dispose();
    _hasText.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<Iterable<String>> _options(TextEditingValue value) async {
    _cancel();
    final query = value.text.trim();
    if (query.isEmpty ||
        query.length > 100 ||
        widget.suggestions == null ||
        !value.composing.isCollapsed) {
      return const [];
    }
    if (_cache.containsKey(query)) return _cache[query]!;
    final generation = _generation;
    final pending = Completer<Iterable<String>>();
    _pending = pending;
    _timer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final suggestions = widget.suggestions;
        if (suggestions == null || !mounted || generation != _generation) {
          if (!pending.isCompleted) pending.complete(const []);
          return;
        }
        _activeRequest = generation;
        _cancelActiveRequest = widget.onCancel;
        final result = (await suggestions(
          query,
        )).where((s) => s.trim().isNotEmpty).toSet().take(10).toList();
        if (generation == _generation && mounted) {
          if (_cache.length >= 32) _cache.remove(_cache.keys.first);
          _cache[query] = result;
          if (!pending.isCompleted) pending.complete(result);
        }
      } catch (_) {
        if (!pending.isCompleted) pending.complete(const []);
      } finally {
        if (_activeRequest == generation) {
          _activeRequest = null;
          _cancelActiveRequest = null;
        }
      }
      if (!pending.isCompleted) pending.complete(const []);
    });
    return pending.future;
  }

  void _submit(String value) {
    _cancel();
    _submitting = true;
    try {
      widget.controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      _syncOptions();
    } finally {
      _submitting = false;
    }
    _focus.unfocus();
    widget.onSearch(value.trim());
  }

  Widget _highlight(String value) {
    final query = widget.controller.text.trim().toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (query.isNotEmpty) {
      final match = value.toLowerCase().indexOf(query, start);
      if (match < 0) break;
      if (match > start) {
        spans.add(TextSpan(text: value.substring(start, match)));
      }
      spans.add(
        TextSpan(
          text: value.substring(match, match + query.length),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      start = match + query.length;
    }
    if (start < value.length) spans.add(TextSpan(text: value.substring(start)));
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => RawAutocomplete<String>(
      textEditingController: _optionsController,
      focusNode: _focus,
      optionsBuilder: _options,
      onSelected: (value) {
        _selected = true;
        _submit(value);
      },
      fieldViewBuilder: (context, controller, focus, submitted) =>
          TelevisionSearchField(
            controller: widget.controller,
            focusNode: focus,
            autofocus: widget.autofocus,
            textInputAction: TextInputAction.search,
            onChanged: (value) {
              widget.onChanged?.call(value);
            },
            onSubmitted: (value) {
              _selected = false;
              submitted();
              if (!_selected) _submit(value);
            },
            decoration: InputDecoration(
              hintText: widget.hint,
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: ValueListenableBuilder<bool>(
                valueListenable: _hasText,
                builder: (context, hasText, _) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasText)
                      IconButton(
                        tooltip: '清空搜索',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () {
                          _cancel();
                          widget.controller.clear();
                          widget.onChanged?.call('');
                        },
                      ),
                    IconButton(
                      tooltip: '搜索',
                      icon: const Icon(Icons.arrow_forward_rounded),
                      onPressed: () => _submit(widget.controller.text),
                    ),
                  ],
                ),
              ),
            ),
          ),
      optionsViewBuilder: (context, selected, options) {
        final values = options.toList();
        final available =
            MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom;
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: constraints.maxWidth,
              height: min(
                min(300.0, max(96.0, available * .45)),
                values.length * 48.0,
              ),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemExtent: 48,
                itemCount: values.length,
                itemBuilder: (context, index) => ListTile(
                  key: ValueKey('search-suggestion-$index'),
                  selected: AutocompleteHighlightedOption.of(context) == index,
                  leading: const Icon(Icons.search, size: 18),
                  title: _highlight(values[index]),
                  onTap: () => selected(values[index]),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
