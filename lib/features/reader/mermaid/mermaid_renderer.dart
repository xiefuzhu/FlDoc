import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:webview_windows/webview_windows.dart';

import '../../../core/log.dart';
import '../../../core/paths.dart';

class MermaidRenderResult {
  const MermaidRenderResult({this.pngFile, this.svgText, this.error});

  final File? pngFile;
  final String? svgText;
  final String? error;

  bool get ok => pngFile != null || svgText != null;
}

class _RenderJob {
  _RenderJob(this.id, this.source, this.dark, this.cachePath);
  final String id;
  final String source;
  final bool dark;
  final String cachePath;
  final Completer<MermaidRenderResult> completer = Completer();
}

/// Offscreen WebView2 Mermaid renderer with SHA-256 + theme PNG cache (doc 02 §7).
class MermaidRenderer {
  MermaidRenderer._();

  static final MermaidRenderer instance = MermaidRenderer._();

  WebviewController? _controller;
  StreamSubscription? _msgSub;
  bool _initialized = false;
  bool _unavailable = false;
  String? _unavailableReason;
  Completer<bool>? _initCompleter;
  Completer<void>? _pageReady;

  final List<_RenderJob> _queue = [];
  _RenderJob? _active;
  int _seq = 0;

  /// Checks whether Microsoft Edge WebView2 Runtime is installed (Settings -> About).
  static Future<String?> checkWebView2Version() async {
    if (!Platform.isWindows) return null;
    try {
      return await WebviewController.getWebViewVersion();
    } catch (_) {
      return null;
    }
  }

  /// Renders [source] for [dark] theme, returning cached PNG or rendering via WebView2.
  Future<MermaidRenderResult> render(String source, {required bool dark}) async {
    final hash = sha256.convert(utf8.encode(source.trim())).toString();
    final themeKey = dark ? 'dark' : 'light';
    final cachePath = p.join(AppPaths.instance.mermaidCacheDir, '$hash-$themeKey.png');
    final cached = File(cachePath);
    if (cached.existsSync() && cached.lengthSync() > 0) {
      return MermaidRenderResult(pngFile: cached);
    }

    if (!Platform.isWindows) {
      return const MermaidRenderResult(error: '仅 Windows 支持 Mermaid 渲染');
    }
    if (_unavailable) {
      return MermaidRenderResult(error: _unavailableReason ?? 'WebView2 不可用');
    }

    final ok = await _ensureInitialized();
    if (!ok) {
      return MermaidRenderResult(error: _unavailableReason ?? 'WebView2 初始化失败');
    }

    final job = _RenderJob('m${++_seq}', source, dark, cachePath);
    _queue.add(job);
    _pump();
    return job.completer.future;
  }

  Future<bool> _ensureInitialized() async {
    if (_initialized) return true;
    if (_unavailable) return false;
    if (_initCompleter != null) return _initCompleter!.future;

    _initCompleter = Completer<bool>();
    try {
      final ver = await WebviewController.getWebViewVersion();
      if (ver == null || ver.isEmpty) {
        _unavailable = true;
        _unavailableReason = '未检测到 WebView2 Runtime，降级为源码显示';
        _initCompleter!.complete(false);
        return false;
      }

      // Copy bundled render.html and mermaid.min.js to supportDir/mermaid_host so
      // WebView2 can map it to https://mermaid.local/ offline without tainted canvas.
      final hostDir = p.join(AppPaths.instance.cacheDir, 'mermaid_host');
      Directory(hostDir).createSync(recursive: true);
      final htmlText = await rootBundle.loadString('assets/mermaid/render.html');
      await File(p.join(hostDir, 'render.html')).writeAsString(htmlText);

      final jsDest = File(p.join(hostDir, 'mermaid.min.js'));
      if (!jsDest.existsSync() || jsDest.lengthSync() < 100000) {
        final jsBytes = await rootBundle.load('assets/mermaid/mermaid.min.js');
        await jsDest.writeAsBytes(jsBytes.buffer.asUint8List(), flush: true);
      }

      final ctrl = WebviewController();
      await ctrl.initialize();
      await ctrl.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await ctrl.addVirtualHostNameMapping('mermaid.local', hostDir, WebviewHostResourceAccessKind.allow);

      _pageReady = Completer<void>();
      _msgSub = ctrl.webMessage.listen(_onMessage);
      await ctrl.loadUrl('https://mermaid.local/render.html');

      await _pageReady!.future.timeout(const Duration(seconds: 10));
      _controller = ctrl;
      _initialized = true;
      _initCompleter!.complete(true);
      return true;
    } catch (e, st) {
      Log.warn('Mermaid WebView2 init failed: $e\n$st');
      _unavailable = true;
      _unavailableReason = 'Mermaid 渲染引擎初始化失败：$e';
      if (!_initCompleter!.isCompleted) _initCompleter!.complete(false);
      return false;
    }
  }

  void _onMessage(dynamic msg) {
    if (msg is! Map) return;
    if (msg['type'] == 'ready') {
      if (_pageReady != null && !_pageReady!.isCompleted) {
        _pageReady!.complete();
      }
      return;
    }
    final job = _active;
    if (job == null || msg['id'] != job.id) return;
    _active = null;
    if (msg['error'] != null) {
      job.completer.complete(MermaidRenderResult(error: msg['error'].toString()));
    } else if (msg['png'] is String && (msg['png'] as String).isNotEmpty) {
      try {
        final bytes = base64Decode(msg['png'] as String);
        final file = File(job.cachePath);
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(bytes, flush: true);
        job.completer.complete(MermaidRenderResult(pngFile: file));
      } catch (e) {
        job.completer.complete(MermaidRenderResult(error: '保存 Mermaid 缓存失败：$e'));
      }
    } else if (msg['svg'] is String && (msg['svg'] as String).isNotEmpty) {
      job.completer.complete(MermaidRenderResult(svgText: msg['svg'] as String));
    } else {
      job.completer.complete(const MermaidRenderResult(error: 'Mermaid 未返回图像数据'));
    }
    _pump();
  }

  void _pump() {
    if (_active != null || _queue.isEmpty) return;
    final ctrl = _controller;
    if (ctrl == null) return;
    final job = _queue.removeAt(0);
    _active = job;

    // 5-second timeout per diagram (doc 02 §7).
    Timer(const Duration(seconds: 5), () {
      if (_active == job && !job.completer.isCompleted) {
        _active = null;
        job.completer.complete(const MermaidRenderResult(error: 'Mermaid 渲染超时（5 秒）'));
        _pump();
      }
    });

    ctrl.postWebMessage(jsonEncode({
      'type': 'render',
      'id': job.id,
      'source': job.source,
      'dark': job.dark,
    }));
  }

  Future<void> dispose() async {
    await _msgSub?.cancel();
    try {
      await _controller?.dispose();
    } catch (_) {}
    _controller = null;
    _initialized = false;
  }
}
