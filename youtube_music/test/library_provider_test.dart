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
    test('throws auth-required rather than returning an empty page',
        () async {
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
    });

    test('the browse id is the liked-songs playlist', () async {
      harness.http.enqueueJson(fixture('liked_music.json'));
      await harness.library.likedTracks(SwayveBrowseRequest.first);
      expect(harness.lastBody['browseId'], 'VLLM');
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
