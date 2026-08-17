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

  group('tracks() — the chart feed', () {
    test('recent maps to the trending chart', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('charts_top.json'));

      await harness.catalog.tracks(
        const SwayveBrowseRequest(sort: SwayveSortOrder.recent),
      );

      final Uri requested = harness.requestedUrls.last;
      expect(requested.path, '/charts');
      expect(requested.queryParameters['kind'], 'trending');
    });

    test('everything else falls back to the top chart', () async {
      // client_id is scraped once and cached for the client's lifetime, so
      // only the very first request needs the scrape queued ahead of it.
      harness.enqueueClientId();
      for (final SwayveSortOrder? sort in <SwayveSortOrder?>[
        null,
        SwayveSortOrder.popular,
        SwayveSortOrder.relevance,
        SwayveSortOrder.alphabetical,
      ]) {
        harness.http.enqueueText(fixtureText('charts_top.json'));

        await harness.catalog.tracks(SwayveBrowseRequest(sort: sort));

        final Uri requested = harness.requestedUrls.last;
        expect(requested.queryParameters['kind'], 'top', reason: '$sort');
      }
    });

    test('unwraps the {"track": {...}} chart envelope', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('charts_top.json'));

      final SwayvePage<SwayveTrack> page =
          await harness.catalog.tracks(SwayveBrowseRequest.first);

      expect(page.items, hasLength(3));
      expect(page.items.first.title, 'Chart Hit One');
      expect(page.items.first.id.value, 't5001');
    });

    test('the region setting reaches the wire and a mid-session change is picked up', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('charts_top.json'));
      await harness.catalog.tracks(SwayveBrowseRequest.first);
      expect(harness.requestedUrls.last.queryParameters.containsKey('region'), isFalse);

      harness.context.fakeSettings.set(kRegionSettingId, 'US');
      harness.http.enqueueText(fixtureText('charts_top.json'));
      await harness.catalog.tracks(SwayveBrowseRequest.first);
      expect(harness.requestedUrls.last.queryParameters['region'], 'US');
    });
  });

  group('artists() — derived from the chart', () {
    test('dedups repeat uploaders across chart tracks', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('charts_top.json'));

      final SwayvePage<SwayveArtist> page =
          await harness.catalog.artists(SwayveBrowseRequest.first);

      // Three chart tracks, two unique uploaders.
      expect(page.items, hasLength(2));
      expect(
        page.items.map((a) => a.name),
        containsAll(<String>['ChartArtistOne', 'ChartArtistTwo']),
      );
    });
  });

  group('albums() — the discovery feed', () {
    test('filters to is_album: true', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('discovery_flat.json'));

      final SwayvePage<SwayveAlbum> page =
          await harness.catalog.albums(SwayveBrowseRequest.first);

      expect(page.items, hasLength(1));
      expect(page.items.single.title, 'A Real Album');
    });

    test('falls back to the sectioned shape when there is no flat collection', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('discovery_sectioned.json'));

      final SwayvePage<SwayveAlbum> page =
          await harness.catalog.albums(SwayveBrowseRequest.first);

      expect(page.items, hasLength(1));
      expect(page.items.single.title, 'Sectioned Album');
    });
  });

  group('album(id) — a real lookup', () {
    test('returns a hydrated album for an is_album playlist id', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('playlist_full.json'));

      final SwayveAlbum? album =
          await harness.catalog.album(SoundCloudIds.playlist(7001));

      expect(album, isNotNull);
      expect(album!.title, 'Fully Hydrated Album');
      expect(album.tracks, hasLength(2));
      expect(album.tracks.map((t) => t.title), <String>['Track One', 'Track Two']);
    });

    test('null for a foreign or wrong-kind id, without a request', () async {
      final SwayveAlbum? foreign =
          await harness.catalog.album(const SwayveMediaId('other.plugin', 't1'));
      expect(foreign, isNull);

      final SwayveAlbum? wrongKind =
          await harness.catalog.album(SoundCloudIds.track(1));
      expect(wrongKind, isNull);
      expect(harness.http.requests, isEmpty);
    });

    test('null when the id no longer resolves', () async {
      harness.enqueueClientId();
      harness.http.enqueueResponse(const SwayveHttpResponse(statusCode: 404));

      final SwayveAlbum? album =
          await harness.catalog.album(SoundCloudIds.playlist(999999));
      expect(album, isNull);
    });

    test('null when the playlist is not actually an album', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('playlist_with_stubs.json'));

      final SwayveAlbum? album =
          await harness.catalog.album(SoundCloudIds.playlist(7002));
      expect(album, isNull);
    });
  });

  group('artist(id) — a real lookup', () {
    test('returns the user for a user id', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('user_full.json'));

      final SwayveArtist? artist =
          await harness.catalog.artist(SoundCloudIds.user(555666));

      expect(artist, isNotNull);
      expect(artist!.name, 'TestArtist');
      expect(artist.extra['countryCode'], 'DE');
    });

    test('null for a wrong-kind id, without a request', () async {
      final SwayveArtist? artist =
          await harness.catalog.artist(SoundCloudIds.track(1));
      expect(artist, isNull);
      expect(harness.http.requests, isEmpty);
    });
  });
}
