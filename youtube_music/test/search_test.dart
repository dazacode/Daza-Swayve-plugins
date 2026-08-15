import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';
import 'package:youtube_music/youtube_music.dart';

import 'support.dart';

void main() {
  late PluginHarness harness;

  setUp(() async {
    harness = await PluginHarness.start();
  });

  tearDown(() => harness.stop());

  group('search normalizes a realistic payload', () {
    test('parses tracks, albums, artists and playlists', () async {
      harness.http.enqueueJson(fixture('search_all.json'));

      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(text: 'aster vale'),
      );

      expect(result.tracks, hasLength(2));
      expect(result.albums, hasLength(1));
      expect(result.artists, hasLength(1));
      expect(result.playlists, hasLength(1));

      final SwayveTrack track = result.tracks.first;
      expect(track.title, 'Nightdrive');
      expect(track.id.pluginId, kYouTubeMusicPluginId);
      expect(track.id.value, 'kJQP7kiw5Fk');
      expect(track.artists.single.name, 'Aster Vale');
      expect(track.artists.single.id?.value, 'UCq3rGZ1Zs9d0dTqRPcJHXyA');
      expect(track.album?.title, 'Long Way Home');
      expect(track.album?.id?.value, 'MPREb_9nqEki4ZLqI');
      expect(track.duration, const Duration(minutes: 3, seconds: 41));
      expect(track.explicit, isTrue);
      expect(track.extra['playlistId'], 'RDAMVMkJQP7kiw5Fk');
    });

    test('an artist known only by name still becomes an artist ref', () async {
      harness.http.enqueueJson(fixture('search_all.json'));

      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(text: 'aster vale'),
      );

      final SwayveTrack track = result.tracks[1];
      expect(track.title, 'Kestrel Line');
      expect(track.artists.single.name, 'Marrow Court');
      expect(
        track.artists.single.id,
        isNull,
        reason: 'No endpoint means no navigation, but still a named artist.',
      );
      expect(track.duration, const Duration(minutes: 4, seconds: 2));
      expect(track.explicit, isFalse);
    });

    test('every result reports streamable, not downloadable', () async {
      harness.http.enqueueJson(fixture('search_all.json'));

      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(text: 'aster vale'),
      );

      for (final SwayveAvailability availability in <SwayveAvailability>[
        ...result.tracks.map((SwayveTrack t) => t.availability),
        ...result.albums.map((SwayveAlbum a) => a.availability),
      ]) {
        expect(availability.streamable, isTrue);
        expect(availability.downloadable, isFalse);
        expect(availability.onDevice, isFalse);
      }
    });

    test('album and playlist detail survives the round trip', () async {
      harness.http.enqueueJson(fixture('search_all.json'));

      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(text: 'aster vale'),
      );

      final SwayveAlbum album = result.albums.single;
      expect(album.title, 'Long Way Home');
      expect(album.id.value, 'MPREb_9nqEki4ZLqI');
      expect(album.artists.single.name, 'Aster Vale');
      expect(album.year, 2019);

      final SwayveArtist artist = result.artists.single;
      expect(artist.name, 'Aster Vale');
      expect(artist.id.value, 'UCq3rGZ1Zs9d0dTqRPcJHXyA');

      final SwayvePlaylist playlist = result.playlists.single;
      expect(playlist.title, 'Night Roads');
      expect(playlist.ownerName, 'Aster Vale');
      expect(playlist.trackCount, 24);
    });

    test('an unreadable row is skipped and reported as partial', () async {
      harness.http.enqueueJson(fixture('search_all.json'));

      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(text: 'aster vale'),
      );

      expect(
        result.partial,
        isTrue,
        reason: 'The fixture carries one row with no title and no endpoint.',
      );
      expect(result.tracks, hasLength(2));
    });

    test('the continuation token is surfaced as a cursor', () async {
      harness.http.enqueueJson(fixture('search_all.json'));

      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(text: 'aster vale'),
      );

      expect(result.cursor, 'EqYDEgtuaWdodGRyaXZlGpgDQ0FFU0J3b0Y');
      expect(result.hasMore, isTrue);
    });

    test('a cursor is sent back as a continuation', () async {
      harness.http.enqueueJson(fixture('search_all.json'));

      await harness.search.search(
        const SwayveSearchQuery(text: 'aster vale', cursor: 'page-two'),
      );

      expect(harness.lastBody['continuation'], 'page-two');
    });

    test('an empty query makes no request at all', () async {
      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(text: '   '),
      );

      expect(result.isEmpty, isTrue);
      expect(harness.http.requests, isEmpty);
    });
  });

  group('kinds and limit are honoured', () {
    test('a single kind is filtered on the wire and in the result', () async {
      harness.http.enqueueJson(fixture('search_all.json'));

      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(
          text: 'aster vale',
          kinds: <SwayveSearchKind>{SwayveSearchKind.track},
        ),
      );

      expect(
        harness.lastBody['params'],
        YouTubeMusicSearchProvider.filterFor(SwayveSearchKind.track),
        reason: 'One kind means one shelf: ask the service, not the parser.',
      );
      expect(result.tracks, hasLength(2));
      expect(
        result.albums,
        isEmpty,
        reason: 'The payload volunteered albums; the host did not ask for '
            'them, so they must not leak through.',
      );
      expect(result.artists, isEmpty);
      expect(result.playlists, isEmpty);
    });

    test('several kinds make one unfiltered request', () async {
      harness.http.enqueueJson(fixture('search_all.json'));

      await harness.search.search(
        const SwayveSearchQuery(
          text: 'aster vale',
          kinds: <SwayveSearchKind>{
            SwayveSearchKind.track,
            SwayveSearchKind.album,
          },
        ),
      );

      expect(harness.http.requests, hasLength(1));
      expect(harness.lastBody.containsKey('params'), isFalse);
    });

    test('limit is a ceiling per kind, not a total', () async {
      harness.http.enqueueJson(fixture('search_all.json'));

      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(text: 'aster vale', limit: 1),
      );

      expect(result.tracks, hasLength(1));
      expect(result.albums, hasLength(1));
      expect(result.artists, hasLength(1));
      expect(result.playlists, hasLength(1));
    });

    test('a zero limit returns nothing but still succeeds', () async {
      harness.http.enqueueJson(fixture('search_all.json'));

      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(text: 'aster vale', limit: 0),
      );

      expect(result.isEmpty, isTrue);
    });
  });

  group('the region setting reaches the wire', () {
    test('the manifest default is used when nothing is set', () async {
      final PluginHarness fresh = await PluginHarness.start(
        host: const SwayveHostInfo(
          swayveVersion: Version(1, 1, 0),
          swayvePluginApi: 1,
          platform: SwayvePlatform.android,
          locale: 'en',
        ),
      );
      addTearDown(fresh.stop);
      fresh.http.enqueueJson(fixture('search_all.json'));

      await fresh.search.search(const SwayveSearchQuery(text: 'x'));

      final Map<String, Object?> client = _client(fresh.lastBody);
      expect(client['gl'], 'US');
      expect(client['hl'], 'en');
    });

    test("the user's choice beats the host's own region", () async {
      final PluginHarness fresh = await PluginHarness.start(
        settings: const <String, Object?>{'region': 'IN'},
      );
      addTearDown(fresh.stop);
      fresh.http.enqueueJson(fixture('search_all.json'));

      await fresh.search.search(const SwayveSearchQuery(text: 'x'));

      expect(_client(fresh.lastBody)['gl'], 'IN');
    });

    test('a change while running is picked up on the next call', () async {
      harness.context.fakeSettings.set('region', 'GB');
      harness.http.enqueueJson(fixture('search_all.json'));

      await harness.search.search(const SwayveSearchQuery(text: 'x'));

      expect(_client(harness.lastBody)['gl'], 'GB');
    });

    test('a nonsense region falls back rather than being sent', () async {
      final PluginHarness fresh = await PluginHarness.start(
        settings: const <String, Object?>{'region': 'not-a-region'},
      );
      addTearDown(fresh.stop);
      fresh.http.enqueueJson(fixture('search_all.json'));

      await fresh.search.search(const SwayveSearchQuery(text: 'x'));

      expect(_client(fresh.lastBody)['gl'], 'GB');
    });
  });
}

Map<String, Object?> _client(Map<String, Object?> body) {
  final Map<String, Object?> context = body['context']! as Map<String, Object?>;
  return context['client']! as Map<String, Object?>;
}
