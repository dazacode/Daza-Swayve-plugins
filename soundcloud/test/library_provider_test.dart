import 'package:soundcloud/soundcloud.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `SoundCloudLibraryProvider.likedTracks` — capability `personal_library`,
/// the official API's `/me/likes/tracks`.
void main() {
  late PluginHarness harness;

  setUp(() async {
    harness = await PluginHarness.start(timeouts: fastTimeouts);
  });

  tearDown(() => harness.stop());

  Future<void> configureApp() async {
    await harness.credentials.writeSecret(kClientIdSettingId, 'fake-client-id');
    await harness.credentials.writeSecret(
      kClientSecretSettingId,
      'fake-client-secret',
    );
  }

  Future<void> signIn() async {
    await configureApp();
    await harness.credentials.writeSecret(
      'oauth_access_token',
      'valid-access-token',
    );
    await harness.credentials.writeSecret(
      'oauth_refresh_token',
      'valid-refresh-token',
    );
  }

  group('no app configured', () {
    test('throws auth-required rather than returning an empty page', () async {
      await expectLater(
        harness.library.likedTracks(SwayveBrowseRequest.first),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
      expect(harness.http.requests, isEmpty);
    });
  });

  group('app configured but never signed in', () {
    setUp(configureApp);

    test('throws auth-required rather than returning an empty page', () async {
      await expectLater(
        harness.library.likedTracks(SwayveBrowseRequest.first),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
      expect(harness.http.requests, isEmpty);
    });
  });

  group('signed in', () {
    setUp(signIn);

    test('parses the official API\'s liked tracks', () async {
      harness.http.enqueueJson(fixture('official_likes.json'));

      final SwayvePage<SwayveTrack> page = await harness.library.likedTracks(
        SwayveBrowseRequest.first,
      );

      expect(page.items, hasLength(2));
      expect(
        page.items.map((t) => t.title),
        <String>['Official Liked Track One', 'Official Liked Track Two'],
      );
      expect(page.hasMore, isTrue);

      final Uri requested = harness.http.lastRequest!.url;
      expect(requested.host, 'api.soundcloud.com');
      expect(requested.path, '/me/likes/tracks');
    });

    test('sends the access token as an OAuth authorization header', () async {
      harness.http.enqueueJson(fixture('official_likes.json'));
      await harness.library.likedTracks(SwayveBrowseRequest.first);

      final RecordedHttpRequest request = harness.http.lastRequest!;
      expect(request.headers['authorization'], 'OAuth valid-access-token');
    });

    test('a cursor is followed as a complete URL, not rebuilt', () async {
      harness.http.enqueueJson(fixture('official_likes.json'));
      await harness.library.likedTracks(
        const SwayveBrowseRequest(
          cursor: 'https://api.soundcloud.com/me/likes/tracks'
              '?offset=xyz&linked_partitioning=1',
        ),
      );

      final Uri requested = harness.http.lastRequest!.url;
      expect(requested.queryParameters['offset'], 'xyz');
    });

    test('a 401 triggers exactly one refresh, then retries', () async {
      harness.http
        ..enqueueResponse(const SwayveHttpResponse(statusCode: 401))
        ..enqueueJson(fixture('oauth_token.json'))
        ..enqueueJson(fixture('official_likes.json'));

      final SwayvePage<SwayveTrack> page = await harness.library.likedTracks(
        SwayveBrowseRequest.first,
      );

      expect(page.items, hasLength(2));
      // First attempt (401), refresh, retried attempt — three requests.
      expect(harness.http.requests, hasLength(3));
      expect(
        harness.http.requests.last.headers['authorization'],
        'OAuth fake-access-token-abc123',
        reason: 'The retry uses the freshly refreshed token, not the stale '
            'one that was just rejected.',
      );
    });

    test(
        'a 401 that survives the refresh throws auth-required, clearing '
        'the session', () async {
      harness.http
        ..enqueueResponse(const SwayveHttpResponse(statusCode: 401))
        ..enqueueResponse(
          SwayveHttpResponse.json(
            <String, Object?>{'error': 'invalid_grant'},
            statusCode: 401,
          ),
        );

      await expectLater(
        harness.library.likedTracks(SwayveBrowseRequest.first),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
      expect(
        await harness.credentials.readSecret('oauth_access_token'),
        isNull,
        reason: 'A refresh token SoundCloud rejects ends the whole session, '
            'not just this one call.',
      );
    });

    test('an expired stored token is refreshed before the fetch, not after',
        () async {
      await harness.credentials.writeSecret(
        'oauth_access_token_expires_at',
        DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
      );
      harness.http
        ..enqueueJson(fixture('oauth_token.json'))
        ..enqueueJson(fixture('official_likes.json'));

      await harness.library.likedTracks(SwayveBrowseRequest.first);

      expect(harness.http.requests, hasLength(2));
      expect(harness.http.requests.first.url.host, kOAuthTokenUri.host);
    });

    test('honours cancellation', () async {
      final SwayveCancellationTokenSource source =
          SwayveCancellationTokenSource()..cancel();
      await expectLater(
        harness.library.likedTracks(
          SwayveBrowseRequest.first,
          cancel: source.token,
        ),
        throwsA(isA<SwayvePluginCancelledException>()),
      );
      expect(harness.http.requests, isEmpty);
    });
  });
}
