import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';
import 'package:youtube_music/youtube_music.dart';

import 'support.dart';

/// `YouTubeMusicLibraryProvider.likedTracks` — capability `personal_library`.
void main() {
  late PluginHarness harness;

  setUp(() async {
    harness = await PluginHarness.start();
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
  });

  group('signed in', () {
    setUp(() async {
      await harness.credentials.writeSecret(
        kSessionCookieSettingId,
        'SID=abc; __Secure-3PAPISID=secret-value',
      );
    });

    test('parses liked tracks through the shared feed parser', () async {
      harness.http.enqueueJson(fixture('liked_music.json'));
      final SwayvePage<SwayveTrack> page = await harness.library.likedTracks(
        SwayveBrowseRequest.first,
      );

      expect(page.items, hasLength(2));
      expect(page.items.first.title, 'Nightdrive');
      expect(page.items.first.artists.single.name, 'Aster Vale');
      expect(
        page.items.first.duration,
        const Duration(minutes: 3, seconds: 41),
      );
      expect(page.items[1].title, 'Harbour Lights');
      expect(page.hasMore, isTrue);
    });

    test('a session with nothing liked yet is an empty page, not an error',
        () async {
      harness.http.enqueueJson(fixture('liked_music_empty.json'));
      final SwayvePage<SwayveTrack> page = await harness.library.likedTracks(
        SwayveBrowseRequest.first,
      );

      expect(page.items, isEmpty);
      expect(page.hasMore, isFalse);
    });

    test('the cursor is handed straight back as a continuation', () async {
      harness.http.enqueueJson(fixture('liked_music.json'));
      await harness.library.likedTracks(
        const SwayveBrowseRequest(cursor: 'next-page'),
      );
      expect(harness.lastBody['continuation'], 'next-page');
    });

    test(
        'a continuation page answered as onResponseReceivedActions parses, '
        'rather than throwing malformed-response', () async {
      // Confirmed against a real Liked Music playlist: past the first page,
      // InnerTube stops answering in the continuationContents shape entirely
      // and switches to a flat onResponseReceivedActions list instead — see
      // liked_music_continuation.json and feed_parser.dart's
      // _appendedContinuationItems.
      harness.http.enqueueJson(fixture('liked_music_continuation.json'));
      final SwayvePage<SwayveTrack> page = await harness.library.likedTracks(
        const SwayveBrowseRequest(cursor: 'next-page'),
      );

      expect(page.items, hasLength(1));
      expect(page.items.single.title, 'Tideline');
      expect(page.hasMore, isTrue);
    });

    test('the browse carries the stored cookie and a computed authorization',
        () async {
      harness.http.enqueueJson(fixture('liked_music.json'));
      await harness.library.likedTracks(SwayveBrowseRequest.first);

      final RecordedHttpRequest request = harness.http.lastRequest!;
      expect(
        request.headers['cookie'],
        'SID=abc; __Secure-3PAPISID=secret-value',
      );
      expect(request.headers['authorization'], startsWith('SAPISIDHASH '));
      expect(request.headers['x-goog-authuser'], '0');
      expect(
        request.headers.containsKey('x-goog-pageid'),
        isFalse,
        reason: 'No page_id stored means no channel to select — the ordinary '
            'case, one channel per account.',
      );
    });

    test('sends the stored page id as x-goog-pageid when one is configured',
        () async {
      await harness.credentials.writeSecret(kPageIdSettingId, '123456789');
      harness.http.enqueueJson(fixture('liked_music.json'));
      await harness.library.likedTracks(SwayveBrowseRequest.first);

      final RecordedHttpRequest request = harness.http.lastRequest!;
      expect(request.headers['x-goog-pageid'], '123456789');
    });

    test(
        'a configured page id InnerTube does not recognise names the '
        'setting, not a fresh sign-in', () async {
      // The same placeholder response as a signed-out cookie — YouTube does
      // not distinguish "wrong channel" from "not signed in" — but the
      // message has to point at the setting actually worth checking.
      await harness.credentials.writeSecret(kPageIdSettingId, 'wrong-channel');
      harness.http.enqueueJson(fixture('liked_music_signed_out.json'));
      await expectLater(
        harness.library.likedTracks(SwayveBrowseRequest.first),
        throwsA(
          isA<SwayvePluginAuthRequiredException>().having(
            (SwayvePluginAuthRequiredException e) => e.message,
            'message',
            contains('channel ID'),
          ),
        ),
      );
    });

    test('the browse id is the liked-songs playlist', () async {
      harness.http.enqueueJson(fixture('liked_music.json'));
      await harness.library.likedTracks(SwayveBrowseRequest.first);
      expect(harness.lastBody['browseId'], 'VLLM');
    });

    test(
        'a cookie InnerTube does not honour throws auth-required, not an '
        'empty page', () async {
      // Mirrors `auth_provider_test.dart`'s equivalent case: a stale or
      // unrecognised cookie gets a normal 200 carrying YouTube Music's own
      // "sign in to see your liked songs" placeholder, which parses as an
      // empty feed unless this is checked for by name.
      harness.http.enqueueJson(fixture('liked_music_signed_out.json'));
      await expectLater(
        harness.library.likedTracks(SwayveBrowseRequest.first),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
    });

    test('an empty stored cookie is treated as signed out', () async {
      await harness.credentials.writeSecret(kSessionCookieSettingId, '   ');
      await expectLater(
        harness.library.likedTracks(SwayveBrowseRequest.first),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
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
