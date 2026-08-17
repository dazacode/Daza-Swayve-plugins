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

  group('playlists() — the discovery feed, unfiltered', () {
    test('returns every discovered playlist regardless of is_album', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('discovery_flat.json'));

      final SwayvePage<SwayvePlaylist> page =
          await harness.playlist.playlists(SwayveBrowseRequest.first);

      expect(page.items, hasLength(1));
      expect(page.items.single.title, 'A Plain Playlist');
    });
  });

  group('playlistTracks(id)', () {
    test('returns tracks in order for a fully hydrated playlist', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('playlist_full.json'));

      final SwayvePage<SwayveTrack> page = await harness.playlist.playlistTracks(
        SoundCloudIds.playlist(7001),
        SwayveBrowseRequest.first,
      );

      expect(page.items.map((t) => t.title), <String>['Track One', 'Track Two']);
    });

    test('hydrates stub tracks and splices them back into position', () async {
      harness.enqueueClientId();
      harness.http
        ..enqueueText(fixtureText('playlist_with_stubs.json'))
        ..enqueueText(fixtureText('stub_hydration_batch.json'));

      final SwayvePage<SwayveTrack> page = await harness.playlist.playlistTracks(
        SoundCloudIds.playlist(7002),
        SwayveBrowseRequest.first,
      );

      expect(page.items.map((t) => t.title), <String>[
        'Hydrated Opener',
        'Hydrated Second',
        'Hydrated Third',
      ]);
      expect(page.items[1].availability.downloadable, isTrue);

      final Uri hydrationRequest = harness.requestedUrls.last;
      expect(hydrationRequest.path, '/tracks');
      expect(hydrationRequest.queryParameters['ids'], '9102,9103');
    });

    test('a batch that fails to hydrate keeps its stubs absent rather than crashing', () async {
      harness.enqueueClientId();
      harness.http
        ..enqueueText(fixtureText('playlist_with_stubs.json'))
        ..enqueueResponse(const SwayveHttpResponse(statusCode: 500));

      final SwayvePage<SwayveTrack> page = await harness.playlist.playlistTracks(
        SoundCloudIds.playlist(7002),
        SwayveBrowseRequest.first,
      );

      // Only the already-hydrated opener survives; the failed batch's two
      // stubs are simply absent, not a crashed lookup.
      expect(page.items.map((t) => t.title), <String>['Hydrated Opener']);
    });

    test('empty page for a foreign or wrong-kind id, without a request', () async {
      final SwayvePage<SwayveTrack> foreign = await harness.playlist.playlistTracks(
        const SwayveMediaId('other.plugin', 'p1'),
        SwayveBrowseRequest.first,
      );
      expect(foreign.items, isEmpty);

      final SwayvePage<SwayveTrack> wrongKind = await harness.playlist.playlistTracks(
        SoundCloudIds.track(1),
        SwayveBrowseRequest.first,
      );
      expect(wrongKind.items, isEmpty);
      expect(harness.http.requests, isEmpty);
    });

    test('empty page when the playlist no longer resolves', () async {
      harness.enqueueClientId();
      harness.http.enqueueResponse(const SwayveHttpResponse(statusCode: 404));

      final SwayvePage<SwayveTrack> page = await harness.playlist.playlistTracks(
        SoundCloudIds.playlist(999999),
        SwayveBrowseRequest.first,
      );
      expect(page.items, isEmpty);
    });
  });
}
