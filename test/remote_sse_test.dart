// Tests for the pure SSE delta parser and cloud model HTTP error handling. No
// network and no provider - mocked clients feed the exact shapes OpenAI-compatible
// endpoints and OpenRouter emit.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cura/features/ai/remote/remote_ai_config.dart';
import 'package:cura/features/ai/remote/cloud_privacy_gate.dart';
import 'package:cura/features/ai/remote/remote_chat_backend.dart';

Stream<String> _lines(List<String> lines) => Stream.fromIterable(lines);

const _openRouterCfg = RemoteAiConfig(
  providerId: 'openrouter',
  baseUrl: 'https://openrouter.ai/api/v1',
  apiKey: 'sk-test',
  modelId: 'google/gemma-4-31b-it:free',
);

const _customCfg = RemoteAiConfig(
  providerId: 'custom',
  baseUrl: 'https://example.test/v1',
  apiKey: 'sk-test',
  modelId: 'missing/model',
);

const _nvidiaCfg = RemoteAiConfig(
  providerId: 'nvidia',
  baseUrl: 'https://integrate.api.nvidia.com/v1',
  apiKey: 'nvapi-test',
  modelId: 'meta/llama-3.1-8b-instruct',
);

void main() {
  group('parseSseContent', () {
    test('concatenates delta content in order', () async {
      final out = await parseSseContent(
        _lines([
          'data: {"choices":[{"delta":{"content":"Hel"}}]}',
          'data: {"choices":[{"delta":{"content":"lo"}}]}',
          'data: {"choices":[{"delta":{"content":" there"}}]}',
          'data: [DONE]',
        ]),
      ).join();
      expect(out, 'Hello there');
    });

    test('skips role-only opening delta and blank/keepalive lines', () async {
      final out = await parseSseContent(
        _lines([
          ': OPENROUTER PROCESSING',
          '',
          'data: {"choices":[{"delta":{"role":"assistant"}}]}',
          'data: {"choices":[{"delta":{"content":"Hi"}}]}',
          '',
          'data: [DONE]',
        ]),
      ).join();
      expect(out, 'Hi');
    });

    test('stops at [DONE] and ignores anything after', () async {
      final out = await parseSseContent(
        _lines([
          'data: {"choices":[{"delta":{"content":"one"}}]}',
          'data: [DONE]',
          'data: {"choices":[{"delta":{"content":"two"}}]}',
        ]),
      ).join();
      expect(out, 'one');
    });

    test('ignores malformed json without aborting the stream', () async {
      final out = await parseSseContent(
        _lines([
          'data: {"choices":[{"delta":{"content":"a"}}]}',
          'data: {not valid json',
          'data: {"choices":[{"delta":{"content":"b"}}]}',
          'data: [DONE]',
        ]),
      ).join();
      expect(out, 'ab');
    });

    test('handles empty content deltas and a missing choices array', () async {
      final out = await parseSseContent(
        _lines([
          'data: {"choices":[{"delta":{"content":""}}]}',
          'data: {"choices":[]}',
          'data: {"id":"x","object":"chat.completion.chunk"}',
          'data: {"choices":[{"delta":{"content":"ok"}}]}',
          'data: [DONE]',
        ]),
      ).join();
      expect(out, 'ok');
    });

    test('throws on OpenRouter top-level stream error', () async {
      final stream = parseSseContent(
        _lines([
          'data: {"choices":[{"delta":{"content":"partial"}}]}',
          'data: {"error":{"code":429,"message":"Free model limit reached","metadata":{"error_type":"rate_limit_exceeded","provider_code":"free-models"}}}',
        ]),
      );

      await expectLater(
        stream.drain<void>(),
        throwsA(
          isA<RemoteAiException>().having(
            (e) => e.message,
            'message',
            contains('Free model limit reached'),
          ),
        ),
      );
    });

    test('throws on choice-level stream error', () async {
      final stream = parseSseContent(
        _lines([
          'data: {"choices":[{"finish_reason":"error","error":{"code":503,"message":"Provider overloaded","metadata":{"error_type":"provider_overloaded"}}}]}',
        ]),
      );

      await expectLater(
        stream.drain<void>(),
        throwsA(
          isA<RemoteAiException>().having(
            (e) => e.message,
            'message',
            contains('Provider overloaded'),
          ),
        ),
      );
    });
  });

  group('parseRemoteApiError', () {
    test('extracts OpenRouter message, error type, and provider code', () {
      final error = parseRemoteApiError(
        '{"error":{"code":429,"message":"Free model limit reached","metadata":{"error_type":"rate_limit_exceeded","provider_code":"free-models"}}}',
        fallbackStatus: 429,
      );

      expect(error?.status, 429);
      expect(error?.message, 'Free model limit reached');
      expect(error?.errorType, 'rate_limit_exceeded');
      expect(error?.providerCode, 'free-models');
    });

    test('falls back cleanly on malformed provider bodies', () {
      final error = parseRemoteApiError('not json', fallbackStatus: 500);

      expect(error?.status, 500);
      expect(error?.message, isNull);
    });
  });

  group('RemoteChatBackend errors', () {
    test('NVIDIA NIM uses its hosted OpenAI-compatible endpoint', () async {
      late http.Request sent;
      final backend = RemoteChatBackend(
        _nvidiaCfg,
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
            'data: [DONE]\n\n',
            200,
          );
        }),
      );

      final output = await backend.testConnection();
      backend.close();

      expect(output, 'ok');
      expect(
        sent.url.toString(),
        'https://integrate.api.nvidia.com/v1/chat/completions',
      );
      expect(sent.headers['Authorization'], 'Bearer nvapi-test');
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['model'], 'meta/llama-3.1-8b-instruct');
      expect(body['stream'], isTrue);
    });

    test('serializes only typed cloud-safe messages', () async {
      Map<String, dynamic>? body;
      final backend = RemoteChatBackend(
        _customCfg,
        client: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
            'data: [DONE]\n\n',
            200,
          );
        }),
      );
      const gate = CloudPrivacyGate();
      final output = await backend
          .generate(
            messages: [
              const CloudSafeMessage.developerLiteral(
                role: 'system',
                content: 'Explain supplied facts only.',
              ),
              gate.userMessage(
                'My name is Amber Brown. Explain my ultrasound.',
              ),
            ],
          )
          .join();
      backend.close();

      expect(output, 'ok');
      final messages = body!['messages'] as List<dynamic>;
      expect(messages.toString(), isNot(contains('Amber Brown')));
      expect(messages.toString(), contains('Explain my ultrasound'));
    });

    test(
      'final boundary blocks a risky non-developer message before HTTP',
      () async {
        var called = false;
        final backend = RemoteChatBackend(
          _customCfg,
          client: MockClient((request) async {
            called = true;
            return http.Response('', 500);
          }),
        );
        const gate = CloudPrivacyGate();
        // A user can legitimately type an ID-like value; the conversation scrubber
        // removes it before this final assertion, so inject a placeholder marker to
        // verify the serializer itself still refuses unsafe output.
        final stream = backend.generate(
          messages: [gate.userMessage('Explain [REDACTED] please')],
        );

        await expectLater(
          stream.drain<void>(),
          throwsA(isA<RemoteAiException>()),
        );
        expect(called, isFalse);
        backend.close();
      },
    );

    test(
      '429 includes provider detail, retry-after, and OpenRouter key state',
      () async {
        final backend = RemoteChatBackend(
          _openRouterCfg,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/key')) {
              return http.Response(
                '{"data":{"limit":10,"limit_remaining":0,"is_free_tier":true}}',
                200,
              );
            }
            expect(request.headers['X-OpenRouter-Title'], 'Cura');
            return http.Response(
              '{"error":{"code":429,"message":"Free model limit reached","metadata":{"error_type":"rate_limit_exceeded","provider_code":"free-models"}}}',
              429,
              headers: {'retry-after': '12'},
            );
          }),
        );

        try {
          await backend.testConnection();
          fail('Expected RemoteAiException');
        } on RemoteAiException catch (e) {
          expect(e.message, contains('Free model limit reached'));
          expect(e.message, contains('type: rate_limit_exceeded'));
          expect(e.message, contains('provider: free-models'));
          expect(e.message, contains('Try again in 12 seconds'));
          expect(e.message, contains('free-tier'));
          expect(e.message, contains('0 of 10 credits left'));
        } finally {
          backend.close();
        }
      },
    );

    test('402 includes insufficient-credit detail', () async {
      final backend = RemoteChatBackend(
        _openRouterCfg,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/key')) {
            return http.Response(
              '{"data":{"limit":5,"limit_remaining":0,"is_free_tier":false}}',
              200,
            );
          }
          return http.Response(
            '{"error":{"code":402,"message":"This key has no credits left","metadata":{"error_type":"credits"}}}',
            402,
          );
        }),
      );

      try {
        await backend.testConnection();
        fail('Expected RemoteAiException');
      } on RemoteAiException catch (e) {
        expect(e.message, contains('insufficient credits'));
        expect(e.message, contains('This key has no credits left'));
        expect(e.message, contains('paid-tier'));
      } finally {
        backend.close();
      }
    });

    test('404 includes model id and provider detail', () async {
      final backend = RemoteChatBackend(
        _customCfg,
        client: MockClient((request) async {
          return http.Response(
            '{"error":{"code":404,"message":"No endpoints found for model"}}',
            404,
          );
        }),
      );

      try {
        await backend.testConnection();
        fail('Expected RemoteAiException');
      } on RemoteAiException catch (e) {
        expect(e.message, contains('missing/model'));
        expect(e.message, contains('No endpoints found for model'));
      } finally {
        backend.close();
      }
    });

    test('malformed non-200 body keeps status fallback', () async {
      final backend = RemoteChatBackend(
        _customCfg,
        client: MockClient((request) async => http.Response('not json', 500)),
      );

      try {
        await backend.testConnection();
        fail('Expected RemoteAiException');
      } on RemoteAiException catch (e) {
        expect(e.message, contains('error (500)'));
      } finally {
        backend.close();
      }
    });
  });
}
