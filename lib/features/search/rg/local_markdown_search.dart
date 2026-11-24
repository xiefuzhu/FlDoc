part of 'rg_service.dart';

typedef _LocalSearchRequest = ({
  List<String> queries,
  List<String> dirs,
  String caseMode,
  bool wholeWord,
  bool regex,
  int context,
  int fileLimit,
  int totalLimit,
});

Future<Object> _runLocalSearch(
  _LocalSearchRequest request,
  RgCancelToken? token,
) async {
  List<RgParseOutput> empty() =>
      List.filled(request.queries.length, const RgParseOutput([]));
  if (token?.isCancelled ?? false) return empty();

  final port = ReceivePort();
  final result = Completer<Object>();
  Isolate? worker;
  void stop() {
    worker?.kill(priority: Isolate.immediate);
    if (!result.isCompleted) result.complete(empty());
  }

  final subscription = port.listen((message) {
    if (result.isCompleted) return;
    result.complete(switch (message) {
      final List<RgParseOutput> output => output,
      final String error => error,
      _ => '离线搜索进程意外结束',
    });
  });
  token?._onCancel.add(stop);
  try {
    worker = await Isolate.spawn(
      _scanMarkdown,
      (request, port.sendPort),
      onError: port.sendPort,
      onExit: port.sendPort,
    );
    if (token?.isCancelled ?? false) stop();
    return await result.future;
  } on IsolateSpawnException {
    return '无法启动离线搜索';
  } finally {
    token?._onCancel.remove(stop);
    await subscription.cancel();
    port.close();
  }
}

Future<void> _scanMarkdown((_LocalSearchRequest, SendPort) job) async {
  final (request, port) = job;
  final List<_LocalQuery> queries;
  try {
    queries = request.queries.map((query) {
      var pattern = request.regex ? query : RegExp.escape(query);
      if (request.wholeWord) {
        const word = r'[\p{L}\p{M}\p{N}\p{Pc}\u200c\u200d]';
        pattern = '(?<!$word)(?:$pattern)(?!$word)';
      }
      final caseSensitive = switch (request.caseMode) {
        'ignore' => false,
        'sensitive' => true,
        _ => query != query.toLowerCase(),
      };
      return _LocalQuery(
        RegExp(pattern, caseSensitive: caseSensitive, unicode: true),
      );
    }).toList();
  } on FormatException catch (e) {
    Isolate.exit(port, '搜索表达式无效：${e.message}');
  }

  final seen = <String>{};
  try {
    for (final dir in request.dirs) {
      await for (final file in _markdownFiles(Directory(dir))) {
        if (!seen.add(file.path)) continue;
        await _scanFile(file, queries, request);
        if (queries.every((q) => q.total >= request.totalLimit)) break;
      }
      if (queries.every((q) => q.total >= request.totalLimit)) break;
    }
  } on FileSystemException catch (e) {
    Isolate.exit(port, '无法读取搜索目录：${e.path ?? e.message}');
  }
  Isolate.exit(port, [
    for (final q in queries)
      RgParseOutput(
        q.files,
        totalMatches: q.total,
        truncated: q.total >= request.totalLimit,
      ),
  ]);
}

Stream<File> _markdownFiles(Directory dir) async* {
  await for (final entity in dir.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (name.startsWith('.')) continue;
    if (entity is Directory && name != 'assets') {
      yield* _markdownFiles(entity);
    } else if (entity is File && name.toLowerCase().endsWith('.md')) {
      yield File(p.normalize(p.absolute(entity.path)));
    }
  }
}

class _LocalQuery {
  _LocalQuery(this.pattern);

  final RegExp pattern;
  final files = <RgRawFileHits>[];
  int total = 0;
}

Future<void> _scanFile(
  File file,
  List<_LocalQuery> queries,
  _LocalSearchRequest request,
) async {
  final pending = {
    for (final q in queries)
      if (q.total < request.totalLimit) q: RgRawFileHits(file.path),
  };
  final before = <String>[];
  var lineNumber = 0;
  try {
    final lines = file
        .openRead()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.contains('\u0000')) return;
      lineNumber++;
      final context = request.context;
      final contextText = context > 0
          ? _preview(line.trimRight(), const []).text
          : '';
      var needsMoreLines = false;
      for (final entry in pending.entries) {
        final q = entry.key;
        final matches = entry.value.matches;
        if (context > 0) {
          for (final hit in matches.reversed) {
            if (lineNumber - hit.lineNumber > context) break;
            hit.contextAfter.add(contextText);
          }
        }
        final limit = request.fileLimit < request.totalLimit - q.total
            ? request.fileLimit
            : request.totalLimit - q.total;
        if (matches.length < limit) {
          final found = q.pattern.allMatches(line).iterator;
          if (found.moveNext()) {
            final start = _previewStart(found.current.start);
            final ranges = <SubmatchRange>[];
            do {
              final hit = found.current;
              if (hit.start - start >= _previewWidth) break;
              if (hit.end > hit.start) {
                ranges.add(SubmatchRange(hit.start, hit.end));
              }
            } while (found.moveNext());
            final preview = _preview(line.trimRight(), ranges, start: start);
            matches.add(
              RgRawMatch(
                lineNumber: lineNumber,
                lineText: preview.text,
                submatches: preview.ranges,
                contextBefore: List.of(before),
                contextAfter: [],
              ),
            );
          }
        }
        needsMoreLines |=
            matches.length < limit ||
            (matches.isNotEmpty &&
                lineNumber - matches.last.lineNumber < context);
      }
      if (!needsMoreLines) break;
      if (context > 0) {
        before.add(contextText);
        if (before.length > context) before.removeAt(0);
      }
    }
  } on FileSystemException {
    // A document can be removed while walking a live library.
    if (await file.exists()) rethrow;
    return;
  }
  for (final entry in pending.entries) {
    if (entry.value.matches.isEmpty) continue;
    entry.key.total += entry.value.matches.length;
    entry.key.files.add(entry.value);
  }
}

const _previewWidth = 400;

int _previewStart(int firstHit) =>
    firstHit < _previewWidth - 40 ? 0 : firstHit - 80;

({String text, List<SubmatchRange> ranges}) _preview(
  String line,
  List<SubmatchRange> matches, {
  int start = 0,
}) {
  if (line.length <= start) start = 0;
  // Keep an emoji intact at a preview boundary.
  if (start > 0 && (line.codeUnitAt(start) & 0xFC00) == 0xDC00) start--;
  var end = (start + _previewWidth).clamp(0, line.length);
  if (end < line.length && (line.codeUnitAt(end) & 0xFC00) == 0xDC00) end--;
  final leading = start == 0 ? '' : '…';
  final trailing = end == line.length ? '' : '…';
  return (
    text: '$leading${line.substring(start, end)}$trailing',
    ranges: [
      for (final hit in matches)
        if (hit.start < end)
          SubmatchRange(
            hit.start - start + leading.length,
            hit.end.clamp(start, end) - start + leading.length,
          ),
    ],
  );
}
