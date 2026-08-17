import 'package:soundcloud/soundcloud.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late PluginHarness harness;

  setUp(() async {
    harness = await PluginHarness.start(timeouts: fastTimeouts);
  });
  tearDown(() => harness.stop());

  test('429 becomes rate-limited with retryAfter parsed', () async {
    harness.enqueueClientId();
    harness.http.enqueueResponse(
      const SwayveHttpResponse(
        statusCode: 429,
        headers: <String, String>{'retry-after': '30'},
      ),
    );

    await expectLater(
      harness.catalog.artist(SoundCloudIds.user(1)),
      throwsA(
        isA<SwayvePluginRateLimitedException>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 30),
        ),
      ),
    );
  });

  test('a 5xx becomes unavailable', () async {
    harness.enqueueClientId();
    harness.http.enqueueResponse(const SwayveHttpResponse(statusCode: 503));

    await expectLater(
      harness.catalog.artist(SoundCloudIds.user(1)),
      throwsA(isA<SwayvePluginUnavailableException>()),
    );
  });

  test('a transport failure becomes unavailable', () async {
    harness.enqueueClientId();
    harness.http.enqueueError();

    await expectLater(
      harness.catalog.artist(SoundCloudIds.user(1)),
      throwsA(isA<SwayvePluginUnavailableException>()),
    );
  });

  test('an unexpected error becomes unavailable, carrying the cause', () async {
    harness.enqueueClientId();
    harness.http.enqueueError(StateError('something exotic'));

    try {
      await harness.catalog.artist(SoundCloudIds.user(1));
      fail('expected an exception');
    } on SwayvePluginUnavailableException catch (e) {
      expect(e.cause, isA<StateError>());
    }
  });

  test('a 401 that survives the retry is unavailable, not auth-required', () async {
    harness.enqueueClientId();
    harness.http.enqueueResponse(const SwayveHttpResponse(statusCode: 401));
    harness.enqueueClientId();
    harness.http.enqueueResponse(const SwayveHttpResponse(statusCode: 401));

    await expectLater(
      harness.catalog.artist(SoundCloudIds.user(1)),
      throwsA(isA<SwayvePluginUnavailableException>()),
    );
  });

  test('garbage, truncated or wrong-shaped bodies are malformed, never TypeError', () async {
    harness.enqueueClientId();
    harness.http.enqueueText('not json at all {{{');
    await expectLater(
      harness.catalog.tracks(SwayveBrowseRequest.first),
      throwsA(isA<SwayvePluginMalformedResponseException>()),
    );

    harness.http.enqueueJson(<Object?>['a', 'bare', 'array']);
    await expectLater(
      harness.catalog.tracks(SwayveBrowseRequest.first),
      throwsA(isA<SwayvePluginMalformedResponseException>()),
    );
  });

  test('a hang times out', () async {
    harness.enqueueClientId();
    harness.http.enqueueHang();

    await expectLater(
      harness.catalog.artist(SoundCloudIds.user(1)),
      throwsA(isA<SwayvePluginTimeoutException>()),
    );
  });

  test('a cancelled token is honoured on every provider', () async {
    final SwayveCancellationTokenSource source = SwayveCancellationTokenSource();
    source.cancel();

    await expectLater(
      harness.search.search(
        const SwayveSearchQuery(text: 'x'),
        cancel: source.token,
      ),
      throwsA(isA<SwayvePluginCancelledException>()),
    );
    await expectLater(
      harness.catalog.tracks(SwayveBrowseRequest.first, cancel: source.token),
      throwsA(isA<SwayvePluginCancelledException>()),
    );
    await expectLater(
      harness.stream.resolvePlayback(SoundCloudIds.track(1), cancel: source.token),
      throwsA(isA<SwayvePluginCancelledException>()),
    );
    await expectLater(
      harness.artwork.artwork(SoundCloudIds.track(1), cancel: source.token),
      throwsA(isA<SwayvePluginCancelledException>()),
    );
    await expectLater(
      harness.playlist.playlists(SwayveBrowseRequest.first, cancel: source.token),
      throwsA(isA<SwayvePluginCancelledException>()),
    );
    expect(harness.http.requests, isEmpty);
  });
}
