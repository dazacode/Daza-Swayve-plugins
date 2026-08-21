import 'package:soundcloud/soundcloud.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `SoundCloudLibraryProvider.likedTracks` — capability `personal_library`.
void main() {
  late PluginHarness harness;

  setUp(() async {
    harness = await PluginHarness.start(timeouts: fastTimeouts);
  });

  tearDown(() => harness.stop());

  group('signed out', () {
    test('throws auth-required rather than returning an empty page', () async {
      await expectLater(
        harness.library.likedTracks(SwayveBrowseRequest.first),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
      expect(
        harness.http.requests,
        isEmpty,
        reason: 'No cookie means nothing to send — the check happens before '
            'any request is made.',
      );
    });

    test('an empty stored cookie is treated as signed out', () async {
      await harness.credentials.writeSecret(kSessionCookieSettingId, '   ');
      await expectLater(
        harness.library.likedTracks(SwayveBrowseRequest.first),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
    });
  });

  group('signed in', () {
    setUp(() async {
      await harness.credentials.writeSecret(
        kSessionCookieSettingId,
        'sc_anonymous_id=abc; oauth_token=secret',
      );
    });

    test(
        'resolves the account, then parses its likes, dropping a liked '
        'playlist', () async {
      // One `client_id` scrape for the whole call, not one per request it
      // makes internally — `SoundCloudClient` caches it — so `/me` and
      // `/users/{id}/likes` share the single scrape queued here.
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('me.json'));
      harness.http.enqueueText(fixtureText('user_likes.json'));

      final SwayvePage<SwayveTrack> page = await harness.library.likedTracks(
        SwayveBrowseRequest.first,
      );

      expect(page.items, hasLength(2));
      expect(
        page.items.map((t) => t.title),
        <String>['Liked Track One', 'Liked Track Two'],
      );
      expect(page.hasMore, isTrue);

      final Uri likesRequest = harness.requestedUrls.last;
      expect(likesRequest.path, '/users/42099/likes');
    });

    test(
        'a cookie /me does not recognise throws auth-required, not an '
        'empty page', () async {
      harness.enqueueClientId();
      harness.http.enqueueResponse(const SwayveHttpResponse(statusCode: 401));
      harness.enqueueClientId();
      harness.http.enqueueResponse(const SwayveHttpResponse(statusCode: 401));

      await expectLater(
        harness.library.likedTracks(SwayveBrowseRequest.first),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
    });

    test(
        'the stored cookie is sent on both the identity lookup and the '
        'likes request', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('me.json'));
      harness.http.enqueueText(fixtureText('user_likes.json'));

      await harness.library.likedTracks(SwayveBrowseRequest.first);

      for (final RecordedHttpRequest request in harness.http.requests) {
        if (request.url.path == '/me' || request.url.path.endsWith('/likes')) {
          expect(
            request.headers['cookie'],
            'sc_anonymous_id=abc; oauth_token=secret',
          );
        }
      }
    });

    test(
        'a second page reuses the resolved account rather than asking /me '
        'again', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('me.json'));
      harness.http.enqueueText(fixtureText('user_likes.json'));
      await harness.library.likedTracks(SwayveBrowseRequest.first);
      final int afterFirstPage = harness.http.requests.length;

      harness.http.enqueueText(fixtureText('user_likes.json'));
      await harness.library.likedTracks(
        const SwayveBrowseRequest(
          cursor: 'https://api-v2.soundcloud.com/users/42099/likes'
              '?offset=abc&limit=8',
        ),
      );

      expect(
        harness.http.requests.where((r) => r.url.path == '/me'),
        hasLength(1),
        reason: 'The account only needed resolving once for this cookie.',
      );
      expect(harness.http.requests.length, greaterThan(afterFirstPage));
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
