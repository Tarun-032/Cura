import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'remote_ai_config.dart';
import 'cloud_privacy_gate.dart';
import 'pii_redactor.dart';

/// A failure talking to the cloud provider, with a message already phrased for
/// the user (bad key, no credit, model not found, offline, ...).
class RemoteAiException implements Exception {
  const RemoteAiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Parsed OpenAI/OpenRouter error envelope. OpenRouter's `error_type` is the
/// stable field across normal HTTP failures and mid-stream SSE failures.
class RemoteApiError {
  const RemoteApiError({
    required this.status,
    this.message,
    this.errorType,
    this.providerCode,
  });

  final int? status;
  final String? message;
  final String? errorType;
  final String? providerCode;
}

/// Non-secret OpenRouter key state, fetched from `/key` for diagnostics.
class _OpenRouterKeyInfo {
  const _OpenRouterKeyInfo({
    required this.isFreeTier,
    this.limit,
    this.limitRemaining,
  });

  final bool? isFreeTier;
  final num? limit;
  final num? limitRemaining;
}

/// OpenAI-compatible streaming chat client, the cloud counterpart to the local
/// `LlamaController`. Works against any provider speaking
/// `POST {baseUrl}/chat/completions` with SSE. [ChatMessage] is reused as the
/// message type so one prompt shape serves both engines; the provider applies
/// the chat template server-side, so there is no local templating step.
class RemoteChatBackend {
  RemoteChatBackend(this._config, {http.Client? client})
    : _client = client ?? http.Client();

  final RemoteAiConfig _config;
  final http.Client _client;

  Uri get _endpoint {
    final base = _config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/chat/completions');
  }

  Uri get _keyEndpoint {
    final base = _config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/key');
  }

  bool get _isOpenRouter {
    if (_config.providerId == 'openrouter') return true;
    final host = Uri.tryParse(_config.baseUrl.trim())?.host.toLowerCase();
    return host == 'openrouter.ai' ||
        (host?.endsWith('.openrouter.ai') ?? false);
  }

  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${_config.apiKey.trim()}',
    'Content-Type': 'application/json',
    // OpenRouter uses these for attribution/rankings; harmless elsewhere.
    'HTTP-Referer': 'https://github.com/Tarun-032/cura',
    'X-OpenRouter-Title': 'Cura',
  };

  /// Streams the answer token-by-token (content deltas) for [messages]. Throws
  /// [RemoteAiException] with a user-ready message on a bad response or network
  /// failure - the caller (AiService) turns that into a graceful chunk.
  Stream<String> generate({
    required List<CloudSafeMessage> messages,
    double temperature = 0.2,
    int maxTokens = 1024,
  }) async* {
    // Last-point defence: rebuild every non-developer message from the privacy
    // transform immediately before JSON serialization. Callers cannot make an
    // earlier sanitized/display copy diverge from the literal network payload.
    const privacyGate = CloudPrivacyGate();
    final outboundMessages = <Map<String, String>>[];
    for (final message in messages) {
      final content = privacyGate.sanitizeAtOutboundBoundary(message).trim();
      if (message.origin != CloudMessageOrigin.developerLiteral &&
          (content.isEmpty ||
              containsHardCloudRisk(content) ||
              content.contains('▇') ||
              content.contains('[REDACTED]'))) {
        throw const RemoteAiException(
          'Cura withheld this request because identifying information could not '
          'be removed safely.',
        );
      }
      outboundMessages.add({'role': message.role, 'content': content});
    }
    final request = http.Request('POST', _endpoint)
      ..headers.addAll(_headers)
      ..body = jsonEncode({
        'model': _config.modelId.trim(),
        'stream': true,
        'temperature': temperature,
        'max_tokens': maxTokens,
        'messages': outboundMessages,
      });

    final http.StreamedResponse response;
    try {
      response = await _client.send(request);
    } catch (_) {
      throw const RemoteAiException(
        "Couldn't reach the cloud model. Check your connection, or switch to "
        'the on-device model in Settings.',
      );
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      throw RemoteAiException(
        await _friendlyError(
          response.statusCode,
          body,
          retryAfter: _retryAfter(response.headers),
        ),
      );
    }

    final lines = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    yield* parseSseContent(lines);
  }

  /// A minimal round-trip to verify the key + model + base URL. Returns the
  /// short reply on success; throws [RemoteAiException] with a readable reason
  /// on failure. Reuses [generate] so it exercises the exact same path.
  Future<String> testConnection() async {
    final buf = StringBuffer();
    await for (final tok in generate(
      messages: [
        const CloudSafeMessage.developerLiteral(
          role: 'user',
          content: 'Reply with the single word: ok',
        ),
      ],
      temperature: 0,
      maxTokens: 5,
    )) {
      buf.write(tok);
    }
    return buf.toString().trim();
  }

  void close() => _client.close();

  /// Maps an HTTP status and the provider's error message to a short, actionable
  /// sentence, keeping OpenRouter's typed metadata visible.
  Future<String> _friendlyError(
    int status,
    String body, {
    String? retryAfter,
  }) async {
    final apiError = parseRemoteApiError(body, fallbackStatus: status);
    final detail = apiError?.message;
    final type = apiError?.errorType;
    final providerCode = apiError?.providerCode;
    final retry = retryAfter == null ? '' : ' Try again in $retryAfter.';
    final meta = [
      if (type != null) 'type: $type',
      if (providerCode != null) 'provider: $providerCode',
    ].join(', ');
    final suffix = meta.isEmpty ? '' : ' ($meta)';

    debugPrint(
      '[Cura.ai] remote error status=$status model=${_config.modelId.trim()} '
      'type=${type ?? '-'} providerCode=${providerCode ?? '-'} '
      'retryAfter=${retryAfter ?? '-'}',
    );

    final keyLine = _isOpenRouter && (status == 402 || status == 429)
        ? await _openRouterKeyDiagnostic()
        : null;
    final keySuffix = keyLine == null ? '' : ' $keyLine';

    // OpenRouter free (`:free`) models share a hard, server-side cap that no
    // retry gets around — spell out the ways forward so a 429 isn't a dead end.
    final freeModelHint = _isOpenRouter && status == 429
        ? ' Free models are capped (about 50 requests/day and 20/min, shared '
            'across all free models). Add a little credit to raise the cap, pick '
            'a paid model, or switch provider (e.g. Groq) in Settings.'
        : '';

    switch (status) {
      case 401:
      case 403:
        return detail != null
            ? 'The API key was rejected: $detail'
            : 'The API key was rejected. Check the key in Settings.';
      case 402:
        return detail != null
            ? 'OpenRouter reports insufficient credits: $detail$suffix$keySuffix'
            : 'OpenRouter reports insufficient credits for this key.$keySuffix';
      case 404:
        return detail != null
            ? 'Model "${_config.modelId}" was not found: $detail'
            : 'Model "${_config.modelId}" was not found. Check the model id.';
      case 429:
        return detail != null
            ? 'Rate limited by the provider: $detail$suffix$retry$keySuffix$freeModelHint'
            : 'Rate limited by the provider.$retry$keySuffix$freeModelHint';
      case 503:
        return detail != null
            ? 'The provider is overloaded: $detail$suffix$retry'
            : 'The provider is overloaded. Try another model or wait.$retry';
      default:
        return detail != null
            ? 'Cloud model error ($status): $detail$suffix'
            : 'The cloud model returned an error ($status). Try again later.';
    }
  }

  Future<String?> _openRouterKeyDiagnostic() async {
    try {
      final info = await _openRouterKeyInfo();
      final free = info.isFreeTier == null
          ? null
          : (info.isFreeTier! ? 'free-tier' : 'paid-tier');
      final limit = info.limit == null
          ? 'unlimited'
          : '${_formatNumber(info.limitRemaining)} of ${_formatNumber(info.limit)} credits left';
      return 'OpenRouter key state: ${free ?? 'tier unknown'}, $limit.';
    } on RemoteAiException catch (e) {
      return 'OpenRouter key check failed: ${e.message}';
    } catch (_) {
      return null;
    }
  }

  Future<_OpenRouterKeyInfo> _openRouterKeyInfo() async {
    http.Response response;
    try {
      response = await _client.get(
        _keyEndpoint,
        headers: {'Authorization': 'Bearer ${_config.apiKey.trim()}'},
      );
    } catch (_) {
      throw const RemoteAiException(
        "Couldn't reach OpenRouter to check this key.",
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const RemoteAiException(
        'OpenRouter rejected the API key. Check the key in Settings.',
      );
    }
    if (response.statusCode != 200) {
      final err = parseRemoteApiError(
        response.body,
        fallbackStatus: response.statusCode,
      );
      throw RemoteAiException(
        err?.message ?? 'OpenRouter key check returned ${response.statusCode}.',
      );
    }

    try {
      final json = jsonDecode(response.body);
      final data = json is Map ? json['data'] : null;
      if (data is! Map) throw const FormatException();
      return _OpenRouterKeyInfo(
        isFreeTier: data['is_free_tier'] is bool
            ? data['is_free_tier'] as bool
            : null,
        limit: data['limit'] is num ? data['limit'] as num : null,
        limitRemaining: data['limit_remaining'] is num
            ? data['limit_remaining'] as num
            : null,
      );
    } catch (_) {
      throw const RemoteAiException(
        'OpenRouter key check returned an unreadable response.',
      );
    }
  }
}

String _formatNumber(num? value) {
  if (value == null) return 'unknown';
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(4);
}

String? _retryAfter(Map<String, String> headers) {
  final value = headers['retry-after'] ?? headers['Retry-After'];
  if (value == null || value.trim().isEmpty) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null && seconds > 0) {
    return seconds == 1 ? '1 second' : '$seconds seconds';
  }
  return value.trim();
}

/// Parses OpenAI/OpenRouter error envelopes without logging raw bodies. Public
/// for tests; callers still present only the sanitized fields above.
@visibleForTesting
RemoteApiError? parseRemoteApiError(String body, {int? fallbackStatus}) {
  if (body.trim().isEmpty) {
    return fallbackStatus == null
        ? null
        : RemoteApiError(status: fallbackStatus);
  }
  try {
    final json = jsonDecode(body);
    if (json is! Map) return null;
    final err = json['error'];
    if (err is String) {
      return RemoteApiError(status: fallbackStatus, message: err.trim());
    }
    if (err is! Map) return null;
    final metadata = err['metadata'];
    return RemoteApiError(
      status: err['code'] is int ? err['code'] as int : fallbackStatus,
      message: err['message'] is String
          ? (err['message'] as String).trim()
          : null,
      errorType: metadata is Map && metadata['error_type'] is String
          ? (metadata['error_type'] as String).trim()
          : null,
      providerCode: metadata is Map && metadata['provider_code'] is String
          ? (metadata['provider_code'] as String).trim()
          : null,
    );
  } catch (_) {
    return fallbackStatus == null
        ? null
        : RemoteApiError(status: fallbackStatus);
  }
}

/// Parses an OpenAI-style SSE line stream into content deltas. Pure and
/// stream-based, so it is unit-testable without a network. Keepalives, malformed
/// lines and the terminal `data: [DONE]` are skipped; a mid-stream top-level
/// `error` object surfaces as a failure rather than an empty answer.
Stream<String> parseSseContent(Stream<String> lines) async* {
  await for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || !line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data == '[DONE]') break;
    try {
      final json = jsonDecode(data);
      if (json is! Map) continue;
      final topError = json['error'];
      if (topError is Map || topError is String) {
        final err = parseRemoteApiError(data);
        throw RemoteAiException(
          err?.message == null
              ? 'The cloud model stopped with an error.'
              : 'The cloud model stopped: ${err!.message}',
        );
      }
      final choices = json['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final first = choices.first;
      final choiceError = first is Map ? first['error'] : null;
      if (choiceError is Map || choiceError is String) {
        final err = parseRemoteApiError(jsonEncode({'error': choiceError}));
        throw RemoteAiException(
          err?.message == null
              ? 'The cloud model stopped with an error.'
              : 'The cloud model stopped: ${err!.message}',
        );
      }
      final delta = first is Map ? first['delta'] : null;
      final content = delta is Map ? delta['content'] : null;
      if (content is String && content.isNotEmpty) yield content;
    } on RemoteAiException {
      rethrow;
    } catch (_) {
      // Keepalive or partial/garbled line - skip it, keep streaming.
    }
  }
}
