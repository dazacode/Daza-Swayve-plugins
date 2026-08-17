import 'package:soundcloud/soundcloud.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late PluginHarness harness;

  setUp(() async {
    harness = await PluginHarness.start(timeouts: fastTimeouts);
  });
  tearDown(() => harness.stop());

  group('likedTracks(id) — /users/{id}/likes', () {
    test('returns a page of liked tracks, dropping a liked playlist', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('user_likes.json'));

      final SwayvePage<SwayveTrack> page = await harness.artistActivity
          .likedTracks(SoundCloudIds.user(193), SwayveBrowseRequest.first);

      expect(page.items, hasLength(2));
      expect(
        page.items.map((t) => t.title),
        <String>['Liked Track One', 'Liked Track Two'],
      );
      expect(page.items.first.id.value, 't8001');
      expect(page.cursor, isNotNull);

      final Uri requested = harness.requestedUrls.last;
      expect(requested.path, '/users/193/likes');
    });

    test('an empty, cursor-less page for a wrong-kind id, without a request',
        () async {
      final SwayvePage<SwayveTrack> page =
          await harness.artistActivity.likedTracks(
        SoundCloudIds.track(1),
        SwayveBrowseRequest.first,
      );
      expect(page.items, isEmpty);
      expect(page.cursor, isNull);
      expect(harness.http.requests, isEmpty);
    });

    test('an empty page for a foreign id, without a request', () async {
      final SwayvePage<SwayveTrack> page =
          await harness.artistActivity.likedTracks(
        const SwayveMediaId('other.plugin', 'u193'),
        SwayveBrowseRequest.first,
      );
      expect(page.items, isEmpty);
      expect(harness.http.requests, isEmpty);
    });

    test('a 404 user surfaces as an unavailable failure, not a crash',
        () async {
      // Unlike the single-entity lookups in catalog_provider.dart, a paged
      // listing has no "not found means empty" convention of its own — a
      // 404 here goes through the same throwForStatus path every other
      // non-2xx listing response does.
      harness.enqueueClientId();
      harness.http.enqueueResponse(const SwayveHttpResponse(statusCode: 404));

      await expectLater(
        harness.artistActivity
            .likedTracks(SoundCloudIds.user(999999), SwayveBrowseRequest.first),
        throwsA(isA<SwayvePluginUnavailableException>()),
      );
    });
  });

  group('repostedTracks(id) — /stream/users/{id}/reposts', () {
    test('returns a page of reposted tracks, dropping a playlist repost',
        () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('user_reposts.json'));

      final SwayvePage<SwayveTrack> page = await harness.artistActivity
          .repostedTracks(SoundCloudIds.user(193), SwayveBrowseRequest.first);

      expect(page.items, hasLength(2));
      expect(
        page.items.map((t) => t.title),
        <String>['Reposted Track One', 'Reposted Track Two'],
      );
      expect(page.items.first.id.value, 't8101');
      expect(page.cursor, isNotNull);

      final Uri requested = harness.requestedUrls.last;
      expect(requested.path, '/stream/users/193/reposts');
    });

    test('an empty, cursor-less page for a wrong-kind id, without a request',
        () async {
      final SwayvePage<SwayveTrack> page =
          await harness.artistActivity.repostedTracks(
        SoundCloudIds.playlist(1),
        SwayveBrowseRequest.first,
      );
      expect(page.items, isEmpty);
      expect(page.cursor, isNull);
      expect(harness.http.requests, isEmpty);
    });

    test('a 404 user surfaces as an unavailable failure, not a crash',
        () async {
      harness.enqueueClientId();
      harness.http.enqueueResponse(const SwayveHttpResponse(statusCode: 404));

      await expectLater(
        harness.artistActivity.repostedTracks(
          SoundCloudIds.user(999999),
          SwayveBrowseRequest.first,
        ),
        throwsA(isA<SwayvePluginUnavailableException>()),
      );
    });
  });
}
