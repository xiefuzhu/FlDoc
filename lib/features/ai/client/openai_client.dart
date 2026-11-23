import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../../core/log.dart';

enum AiErrorKind { unauthorized, rateLimited, network, timeout, server, invalidResponse, cancelled }

class AiException implements Exception {
  const AiException(this.kind, this.message, {this.statusCode});

  final AiErrorKind kind;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class ChatDelta {
  const ChatDelta({this.content = '', this.reasoning = ''});
  final String content;
  final String reasoning;
}

class EmbedResponse {
  const EmbedResponse({required this.vectors, required this.dim, required this.elapsedMs});
  final List<Float32List> vectors;
  final int dim;
  final int elapsedMs;
}

class AiCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void onCancel(void Function() cb) {
    if (_cancelled) {
      cb();
    } else {
      _listeners.add(cb);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final cb in List<void Function()>.of(_listeners)) {
      try {
        cb();
      } catch (_) {}
    }
    _listeners.clear();
  }
}

/// OpenAI-compatible HTTP client (`/models`, `/chat/completions`, `/embeddings`).
class OpenAiClient {
  OpenAiClient({http.Client? httpClient}) : _injected = httpClient;

  final http.Client? _injected;

  static String normalizeBaseUrl(String baseUrl) {
    var u = baseUrl.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  static bool isLocalBaseUrl(String baseUrl) {
    final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '0.0.0.0';
  }

  Map<String, String> _headers(String apiKey) => {
        'Content-Type': 'application/json',
        if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
      };

  http.Client _makeClient() => _injected ?? http.Client();

  void _maybeClose(http.Client c) {
    if (_injected == null) c.close();
  }

  /// `GET {baseUrl}/models`
  Future<List<String>> listModels({required String baseUrl, required String apiKey}) async {
    final base = normalizeBaseUrl(baseUrl);
    if (base.isEmpty) throw const AiException(AiErrorKind.invalidResponse, '请先填写 Base URL');
    final client = _makeClient();
    try {
      final resp = await client
          .get(Uri.parse('$base/models'), headers: _headers(apiKey))
          .timeout(const Duration(seconds: 15));
      _checkStatus(resp.statusCode, resp.body);
      final decoded = jsonDecode(resp.body);
      final data = decoded is Map ? decoded['data'] : null;
      if (data is! List) {
        throw const AiException(AiErrorKind.invalidResponse, '模型列表响应格式无效');
      }
      final ids = <String>[];
      for (final item in data) {
        if (item is Map && item['id'] is String) ids.add(item['id'] as String);
      }
      ids.sort();
      return ids;
    } on AiException {
      rethrow;
    } on TimeoutException {
      throw const AiException(AiErrorKind.timeout, '获取模型列表超时，请检查网络或 Base URL');
    } on SocketException catch (e) {
      throw AiException(AiErrorKind.network, '网络连接失败：${e.message}');
    } on http.ClientException catch (e) {
      throw AiException(AiErrorKind.network, '网络请求失败：${e.message}');
    } catch (e) {
      throw AiException(AiErrorKind.invalidResponse, '解析模型列表失败：$e');
    } finally {
      _maybeClose(client);
    }
  }

  /// Non-streaming chat completion (used for query rewrite & test connection).
  Future<String> chatComplete({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, String>> messages,
    double temperature = 0.0,
    int maxTokens = 512,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final base = normalizeBaseUrl(baseUrl);
    final client = _makeClient();
    try {
      final body = jsonEncode({
        'model': model,
        'messages': messages,
        'temperature': temperature,
        'max_tokens': maxTokens,
        'stream': false,
      });
      final resp = await client
          .post(Uri.parse('$base/chat/completions'), headers: _headers(apiKey), body: body)
          .timeout(timeout);
      _checkStatus(resp.statusCode, resp.body);
      final decoded = jsonDecode(resp.body);
      final choices = decoded is Map ? decoded['choices'] : null;
      if (choices is List && choices.isNotEmpty) {
        final msg = choices.first is Map ? choices.first['message'] : null;
        if (msg is Map && msg['content'] is String) {
          return msg['content'] as String;
        }
      }
      return '';
    } on AiException {
      rethrow;
    } on TimeoutException {
      throw const AiException(AiErrorKind.timeout, '对话模型请求超时');
    } on SocketException catch (e) {
      throw AiException(AiErrorKind.network, '网络连接失败：${e.message}');
    } on http.ClientException catch (e) {
      throw AiException(AiErrorKind.network, '网络请求失败：${e.message}');
    } catch (e) {
      throw AiException(AiErrorKind.invalidResponse, '解析对话响应失败：$e');
    } finally {
      _maybeClose(client);
    }
  }

  /// Tests chat model connection with a 1-token ping and returns latency in ms.
  Future<int> testChat({required String baseUrl, required String apiKey, required String model}) async {
    final sw = Stopwatch()..start();
    await chatComplete(
      baseUrl: baseUrl,
      apiKey: apiKey,
      model: model,
      messages: const [
        {'role': 'user', 'content': 'ping'},
      ],
      temperature: 0,
      maxTokens: 1,
      timeout: const Duration(seconds: 20),
    );
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  /// Streaming SSE chat completion (spec 06 §7).
  /// Timeouts: 10s connect, 60s first chunk, 5m total.
  Stream<ChatDelta> streamChat({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<Map<String, String>> messages,
    double temperature = 0.2,
    int maxTokens = 2048,
    String? reasoningEffort,
    AiCancelToken? cancelToken,
  }) async* {
    final base = normalizeBaseUrl(baseUrl);
    final client = _makeClient();
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    var closed = false;
    void closeClient() {
      if (!closed) {
        closed = true;
        _maybeClose(client);
      }
    }

    cancelToken?.onCancel(closeClient);

    try {
      final payload = <String, dynamic>{
        'model': model,
        'messages': messages,
        'temperature': temperature,
        'max_tokens': maxTokens,
        'stream': true,
      };
      if (reasoningEffort != null && reasoningEffort.isNotEmpty && reasoningEffort != 'auto') {
        payload['reasoning_effort'] = reasoningEffort;
      }
      final req = http.Request('POST', Uri.parse('$base/chat/completions'))
        ..headers.addAll(_headers(apiKey))
        ..headers['Accept'] = 'text/event-stream'
        ..body = jsonEncode(payload);

      final streamed = await client.send(req).timeout(const Duration(seconds: 10));
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        final errBody = await streamed.stream.bytesToString().timeout(const Duration(seconds: 5), onTimeout: () => '');
        _checkStatus(streamed.statusCode, errBody);
      }

      var gotFirstChunk = false;
      final lineStream = streamed.stream.transform(utf8.decoder).transform(const LineSplitter());
      final iter = StreamIterator<String>(lineStream);

      while (true) {
        if (cancelToken?.isCancelled ?? false) {
          throw const AiException(AiErrorKind.cancelled, '已停止生成');
        }
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          throw const AiException(AiErrorKind.timeout, '生成总时长超过 5 分钟，已超时');
        }
        final stepTimeout = gotFirstChunk
            ? (remaining < const Duration(seconds: 60) ? remaining : const Duration(seconds: 60))
            : (remaining < const Duration(seconds: 60) ? remaining : const Duration(seconds: 60));

        final hasNext = await iter.moveNext().timeout(stepTimeout);
        if (!hasNext) break;

        final line = iter.current.trim();
        if (line.isEmpty || line.startsWith(':')) continue;
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload == '[DONE]') break;

        Object? decoded;
        try {
          decoded = jsonDecode(payload);
        } catch (_) {
          continue;
        }
        if (decoded is! Map) continue;
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final first = choices.first;
        if (first is! Map) continue;
        final delta = first['delta'];
        if (delta is! Map) continue;

        final content = delta['content'] is String ? delta['content'] as String : '';
        final reasoning = delta['reasoning_content'] is String
            ? delta['reasoning_content'] as String
            : (delta['reasoning'] is String ? delta['reasoning'] as String : '');
        if (content.isNotEmpty || reasoning.isNotEmpty) {
          gotFirstChunk = true;
          yield ChatDelta(content: content, reasoning: reasoning);
        }
      }
      await iter.cancel();
    } on AiException {
      rethrow;
    } on TimeoutException {
      throw const AiException(AiErrorKind.timeout, '模型响应超时，请稍后重试');
    } on SocketException catch (e) {
      if (cancelToken?.isCancelled ?? false) throw const AiException(AiErrorKind.cancelled, '已停止生成');
      throw AiException(AiErrorKind.network, '网络连接失败：${e.message}');
    } on http.ClientException catch (e) {
      if (cancelToken?.isCancelled ?? false) throw const AiException(AiErrorKind.cancelled, '已停止生成');
      throw AiException(AiErrorKind.network, '网络请求失败：${e.message}');
    } catch (e) {
      if (cancelToken?.isCancelled ?? false) throw const AiException(AiErrorKind.cancelled, '已停止生成');
      Log.error('streamChat error', e);
      throw AiException(AiErrorKind.network, '请求异常：$e');
    } finally {
      closeClient();
    }
  }

  /// `POST {baseUrl}/embeddings` (spec 06 §6.3).
  Future<EmbedResponse> embed({
    required String baseUrl,
    required String apiKey,
    required String model,
    required List<String> inputs,
  }) async {
    final base = normalizeBaseUrl(baseUrl);
    if (inputs.isEmpty) return const EmbedResponse(vectors: [], dim: 0, elapsedMs: 0);
    final sw = Stopwatch()..start();
    final client = _makeClient();
    try {
      final resp = await client
          .post(
            Uri.parse('$base/embeddings'),
            headers: _headers(apiKey),
            body: jsonEncode({
              'model': model,
              'input': inputs,
              'encoding_format': 'float',
            }),
          )
          .timeout(const Duration(seconds: 60));
      _checkStatus(resp.statusCode, resp.body);
      final decoded = jsonDecode(resp.body);
      final data = decoded is Map ? decoded['data'] : null;
      if (data is! List || data.length != inputs.length) {
        throw const AiException(AiErrorKind.invalidResponse, '嵌入接口返回的向量数量与输入不一致');
      }
      // Sort by `index` field when present.
      final ordered = List<Map>.from(data.whereType<Map>())
        ..sort((a, b) => ((a['index'] as num?) ?? 0).compareTo((b['index'] as num?) ?? 0));

      final vectors = <Float32List>[];
      var dim = 0;
      for (final item in ordered) {
        final rawVec = item['embedding'];
        if (rawVec is! List || rawVec.isEmpty) {
          throw const AiException(AiErrorKind.invalidResponse, '嵌入响应缺少 embedding 数组');
        }
        final vec = Float32List(rawVec.length);
        for (var i = 0; i < rawVec.length; i++) {
          vec[i] = (rawVec[i] as num).toDouble();
        }
        dim = vec.length;
        vectors.add(vec);
      }
      sw.stop();
      return EmbedResponse(vectors: vectors, dim: dim, elapsedMs: sw.elapsedMilliseconds);
    } on AiException {
      rethrow;
    } on TimeoutException {
      throw const AiException(AiErrorKind.timeout, '嵌入接口请求超时');
    } on SocketException catch (e) {
      throw AiException(AiErrorKind.network, '嵌入接口网络连接失败：${e.message}');
    } on http.ClientException catch (e) {
      throw AiException(AiErrorKind.network, '嵌入接口请求失败：${e.message}');
    } catch (e) {
      throw AiException(AiErrorKind.invalidResponse, '解析嵌入响应失败：$e');
    } finally {
      _maybeClose(client);
    }
  }

  /// Tests embedding connection with `"flDoc"` and returns `(dim, elapsedMs)`.
  Future<({int dim, int elapsedMs})> testEmbedding({
    required String baseUrl,
    required String apiKey,
    required String model,
  }) async {
    final res = await embed(baseUrl: baseUrl, apiKey: apiKey, model: model, inputs: const ['flDoc']);
    return (dim: res.dim, elapsedMs: res.elapsedMs);
  }

  void _checkStatus(int status, String body) {
    if (status >= 200 && status < 300) return;
    if (status == 401 || status == 403) {
      throw AiException(AiErrorKind.unauthorized, '认证失败（HTTP $status），请检查 API Key', statusCode: status);
    }
    if (status == 429) {
      throw AiException(AiErrorKind.rateLimited, '请求过于频繁（HTTP 429），请稍后重试', statusCode: status);
    }
    if (status >= 500) {
      throw AiException(AiErrorKind.server, '服务端错误（HTTP $status），请稍后重试', statusCode: status);
    }
    String detail = '';
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is Map && j['error']['message'] is String) {
        detail = '：${j['error']['message']}';
      }
    } catch (_) {}
    throw AiException(AiErrorKind.invalidResponse, '请求失败（HTTP $status）$detail', statusCode: status);
  }
}
