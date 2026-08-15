import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Spec §19: a provider must complete, honour cancellation, or throw a
/// `SwayvePluginException`. Nothing else may escape. Each test here forces one
/// failure mode and checks the plugin reports it as the right kind — because
/// the host's whole recovery strategy is a switch over that hierarchy, and an
/// error it cannot classify degrades to "temporarily unavailable" with no
/// explanation.
void main() {
  const SwayveSearchQuery query = SwayveSearchQuery(text: 'aster vale');

  group('rate limiting', () {
    test('429 becomes rate limited, with retryAfter in seconds', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueResponse(
        SwayveHttpResponse.text(
          'Too Many Requests',
          statusCode: 429,
          headers: const <String, String>{'retry-after': '120'},
        ),
      );

      await expectLater(
        harness.search.search(query),
        throwsA(
          isA<SwayvePluginRateLimitedException>().having(
            (SwayvePluginRateLimitedException e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 120),
          ),
        ),
      );
    });

    test('429 with an HTTP-date retry-after is understood', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueResponse(
        SwayveHttpResponse.text(
          '',
          statusCode: 429,
          headers: const <String, String>{
            'Retry-After': 'Wed, 21 Oct 2099 07:28:00 GMT',
          },
        ),
      );

      await expectLater(
        harness.search.search(query),
        throwsA(
          isA<SwayvePluginRateLimitedException>().having(
            (SwayvePluginRateLimitedException e) => e.retryAfter,
            'retryAfter',
            isNotNull,
          ),
        ),
      );
    });

    test('an unparseable retry-after is null, not a guess', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueResponse(
        SwayveHttpResponse.text(
          '',
          statusCode: 429,
          headers: const <String, String>{'retry-after': 'soon'},
        ),
      );

      await expectLater(
        harness.search.search(query),
        throwsA(
          isA<SwayvePluginRateLimitedException>().having(
            (SwayvePluginRateLimitedException e) => e.retryAfter,
            'retryAfter',
            isNull,
          ),
        ),
      );
    });
  });

  group('unavailability', () {
    test('a 5xx becomes unavailable', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueResponse(
        SwayveHttpResponse.text('Service Unavailable', statusCode: 503),
      );

      await expectLater(
        harness.search.search(query),
        throwsA(isA<SwayvePluginUnavailableException>()),
      );
    });

    test('a transport failure becomes unavailable', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueError();

      await expectLater(
        harness.search.search(query),
        throwsA(isA<SwayvePluginUnavailableException>()),
      );
    });

    test('an error the plugin did not expect still becomes unavailable',
        () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueError(const FormatException('something exotic'));

      await expectLater(
        harness.search.search(query),
        throwsA(
          isA<SwayvePluginUnavailableException>().having(
            (SwayvePluginUnavailableException e) => e.cause,
            'cause',
            isA<FormatException>(),
          ),
        ),
      );
    });

    test('a 403 is unavailable, not auth-required', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueResponse(
        SwayveHttpResponse.text('Forbidden', statusCode: 403),
      );

      await expectLater(
        harness.search.search(query),
        throwsA(
          allOf(
            isA<SwayvePluginUnavailableException>(),
            isNot(isA<SwayvePluginAuthRequiredException>()),
          ),
        ),
      );
    });
  });

  group('malformed responses', () {
    test('a garbage body is malformed, not a TypeError', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueText('<!DOCTYPE html><html>nope</html>');

      await expectLater(
        harness.search.search(query),
        throwsA(isA<SwayvePluginMalformedResponseException>()),
      );
    });

    test('a truncated JSON body is malformed', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      final String truncated = fixtureText('search_all.json').substring(0, 512);
      harness.http.enqueueText(truncated);

      await expectLater(
        harness.search.search(query),
        throwsA(isA<SwayvePluginMalformedResponseException>()),
      );
    });

    test('valid JSON of the wrong shape is malformed', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueJson(<String, Object?>{'unexpected': true});

      await expectLater(
        harness.search.search(query),
        throwsA(isA<SwayvePluginMalformedResponseException>()),
      );
    });

    test('a JSON array where an object was promised is malformed', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueJson(<Object?>['not', 'an', 'object']);

      await expectLater(
        harness.search.search(query),
        throwsA(isA<SwayvePluginMalformedResponseException>()),
      );
    });

    test('a deeply broken item degrades the row, not the search', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueJson(<String, Object?>{
        'contents': <String, Object?>{
          'tabbedSearchResultsRenderer': <String, Object?>{
            'tabs': <Object?>[
              <String, Object?>{
                'tabRenderer': <String, Object?>{
                  'content': <String, Object?>{
                    'sectionListRenderer': <String, Object?>{
                      'contents': <Object?>[
                        <String, Object?>{
                          'musicShelfRenderer': <String, Object?>{
                            'contents': <Object?>[
                              <String, Object?>{
                                'musicResponsiveListItemRenderer':
                                    <String, Object?>{
                                  'flexColumns': 'this should have been a list',
                                },
                              },
                            ],
                          },
                        },
                      ],
                    },
                  },
                },
              },
            ],
          },
        },
      });

      final SwayveSearchResult result = await harness.search.search(query);
      expect(result.isEmpty, isTrue);
      expect(result.partial, isTrue);
    });
  });

  group('deadlines and cancellation', () {
    test('a hanging request is cut off as a timeout', () async {
      final PluginHarness harness = await PluginHarness.start(
        timeouts: fastTimeouts,
      );
      addTearDown(harness.stop);
      harness.http.enqueueHang();

      await expectLater(
        harness.search.search(query),
        throwsA(
          isA<SwayvePluginTimeoutException>().having(
            (SwayvePluginTimeoutException e) => e.limit,
            'limit',
            fastTimeouts.operation,
          ),
        ),
      );
    });

    test('the request deadline is passed down to the host client', () async {
      final PluginHarness harness = await PluginHarness.start(
        timeouts: fastTimeouts,
      );
      addTearDown(harness.stop);
      harness.http.enqueueJson(fixture('search_all.json'));

      await harness.search.search(query);

      expect(harness.http.lastRequest!.timeout, fastTimeouts.request);
    });

    test('an already-cancelled token stops before any request', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      final SwayveCancellationTokenSource source =
          SwayveCancellationTokenSource()..cancel();

      await expectLater(
        harness.search.search(query, cancel: source.token),
        throwsA(isA<SwayvePluginCancelledException>()),
      );
      expect(harness.http.requests, isEmpty);
    });

    test('cancelling mid-flight stops the operation', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      harness.http.enqueueHang();
      final SwayveCancellationTokenSource source =
          SwayveCancellationTokenSource();

      final Future<SwayveSearchResult> pending = harness.search.search(
        query,
        cancel: source.token,
      );
      scheduleMicrotask(source.cancel);

      await expectLater(
        pending,
        throwsA(isA<SwayvePluginCancelledException>()),
      );
    });

    test('every provider honours a cancelled token', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      final SwayveCancellationTokenSource source =
          SwayveCancellationTokenSource()..cancel();

      await expectLater(
        harness.catalog.albums(
          SwayveBrowseRequest.first,
          cancel: source.token,
        ),
        throwsA(isA<SwayvePluginCancelledException>()),
      );
      await expectLater(
        harness.catalog.album(
          const SwayveMediaId(
            'app.swayve.plugins.youtube_music',
            'MPREb_9nqEki4ZLqI',
          ),
          cancel: source.token,
        ),
        throwsA(isA<SwayvePluginCancelledException>()),
      );
      await expectLater(
        harness.artwork.artwork(
          const SwayveMediaId(
            'app.swayve.plugins.youtube_music',
            'kJQP7kiw5Fk',
          ),
          cancel: source.token,
        ),
        throwsA(isA<SwayvePluginCancelledException>()),
      );
      await expectLater(
        harness.stream.resolvePlayback(
          const SwayveMediaId(
            'app.swayve.plugins.youtube_music',
            'kJQP7kiw5Fk',
          ),
          cancel: source.token,
        ),
        throwsA(isA<SwayvePluginCancelledException>()),
      );
      expect(harness.http.requests, isEmpty);
    });
  });
}
