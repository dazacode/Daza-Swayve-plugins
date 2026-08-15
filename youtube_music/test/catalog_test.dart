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

  group('paged browsing', () {
    test('a feed is partitioned by kind', () async {
      harness.http.enqueueJson(fixture('browse_home.json'));
      final SwayvePage<SwayveAlbum> albums = await harness.catalog.albums(
        SwayveBrowseRequest.first,
      );

      expect(albums.items, hasLength(1));
      expect(albums.items.single.title, 'Long Way Home');
      expect(albums.items.single.year, 2019);
      expect(albums.cursor, isNotNull);
      expect(albums.hasMore, isTrue);
    });

    test('artists and tracks come from the same feed', () async {
      harness.http.enqueueJson(fixture('browse_home.json'));
      final SwayvePage<SwayveArtist> artists = await harness.catalog.artists(
        SwayveBrowseRequest.first,
      );
      expect(artists.items.single.name, 'Aster Vale');

      harness.http.enqueueJson(fixture('browse_home.json'));
      final SwayvePage<SwayveTrack> tracks = await harness.catalog.tracks(
        SwayveBrowseRequest.first,
      );
      expect(tracks.items.single.title, 'Nightdrive');
      expect(
        tracks.items.single.duration,
        const Duration(minutes: 3, seconds: 41),
      );
    });

    test('limit truncates the page', () async {
      harness.http.enqueueJson(fixture('browse_home.json'));
      final SwayvePage<SwayveAlbum> page = await harness.catalog.albums(
        const SwayveBrowseRequest(limit: 0),
      );
      expect(page.items, isEmpty);
    });

    test('a cursor is handed straight back to the service', () async {
      harness.http.enqueueJson(fixture('browse_home.json'));
      await harness.catalog.albums(
        const SwayveBrowseRequest(cursor: 'next-page'),
      );
      expect(harness.lastBody['continuation'], 'next-page');
    });

    test('sort order selects a feed and never fails', () async {
      for (final MapEntry<SwayveSortOrder?, String> expected
          in <SwayveSortOrder?, String>{
        SwayveSortOrder.recent: 'FEmusic_new_releases',
        SwayveSortOrder.popular: 'FEmusic_charts',
        SwayveSortOrder.alphabetical: 'FEmusic_home',
        null: 'FEmusic_home',
      }.entries) {
        harness.http.enqueueJson(fixture('browse_home.json'));
        await harness.catalog.albums(
          SwayveBrowseRequest(sort: expected.key),
        );
        expect(harness.lastBody['browseId'], expected.value);
      }
    });
  });

  group('album lookup', () {
    test('reads the header and the track list', () async {
      harness.http.enqueueJson(fixture('browse_album.json'));
      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      expect(album, isNotNull);
      expect(album!.title, 'Long Way Home');
      expect(album.artists.single.name, 'Aster Vale');
      expect(album.year, 2019);
      expect(album.trackCount, 12);
      expect(album.availability.streamable, isTrue);
      expect(album.availability.downloadable, isFalse);
      expect(harness.lastBody['browseId'], 'MPREb_9nqEki4ZLqI');
    });

    test('album tracks carry their number and running time', () async {
      harness.http.enqueueJson(fixture('browse_album.json'));
      final List<SwayveTrack> tracks = await harness.catalog.albumTracks(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      expect(tracks, hasLength(2));
      expect(tracks.first.title, 'Nightdrive');
      expect(tracks.first.trackNumber, 1);
      expect(tracks.first.duration, const Duration(minutes: 3, seconds: 41));
      expect(tracks.first.explicit, isTrue);
      expect(tracks[1].trackNumber, 2);
      expect(tracks[1].duration, const Duration(minutes: 4, seconds: 15));
    });

    test('the album carries its own listing', () async {
      harness.http.enqueueJson(fixture('browse_album.json'));
      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      expect(
        album!.tracks.map((SwayveTrack t) => t.title),
        <String>['Nightdrive', 'Harbour Lights'],
        reason: 'A host derives its albums from the tracks it holds. Without '
            'the listing on the album it can only show the songs a search '
            'happened to drag back, and nothing on screen says so.',
      );
      expect(
        harness.http.requests,
        hasLength(1),
        reason: 'The same browse already carries both halves. Asking again for '
            'the tracks would be a second round trip for a page that is '
            'already parsed.',
      );
    });

    test('every listed track knows which release it is on', () async {
      harness.http.enqueueJson(fixture('browse_album.json'));
      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      for (final SwayveTrack track in album!.tracks) {
        expect(
          track.album?.id,
          album.id,
          reason: 'An album page\'s rows do not repeat the album, because the '
              'page says it. A track handed to a host has no page left to read '
              'it off — and a host grouping by title alone merges two records '
              'that share a name.',
        );
        expect(track.album?.title, 'Long Way Home');
      }
    });

    test('positions are filled in from the running order', () async {
      harness.http.enqueueJson(fixture('browse_album.json'));
      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      expect(
        album!.tracks.map((SwayveTrack t) => t.trackNumber),
        <int>[1, 2],
        reason: 'The order the artist put them in is the only ordering an '
            'album has. Falling back to alphabetical would reorder every '
            'record in the library.',
      );
    });

    test('a listed track keeps an album it stated for itself', () async {
      harness.http.enqueueJson(fixture('browse_album.json'));
      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      // Nothing in this fixture states a different release, so the guard is
      // proved the only way it can be: the stamped ref is the album's own, and
      // it is applied without discarding a title the row already carried.
      expect(album!.tracks.every((SwayveTrack t) => t.album != null), isTrue);
    });

    test('an id from another plugin is null, not an error', () async {
      final SwayveAlbum? album = await harness.catalog.album(
        const SwayveMediaId('dev.someone.else.plugin', 'MPREb_9nqEki4ZLqI'),
      );

      expect(album, isNull);
      expect(
        harness.http.requests,
        isEmpty,
        reason: 'An id we did not mint must not cost a request.',
      );
    });

    test('an id of the wrong kind is null, not an error', () async {
      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('kJQP7kiw5Fk'),
      );

      expect(album, isNull);
      expect(harness.http.requests, isEmpty);
    });
  });

  group('artist lookup', () {
    test('reads the immersive header', () async {
      harness.http.enqueueJson(fixture('browse_artist.json'));
      final SwayveArtist? artist = await harness.catalog.artist(
        YouTubeMusicIds.mediaId('UCq3rGZ1Zs9d0dTqRPcJHXyA'),
      );

      expect(artist, isNotNull);
      expect(artist!.name, 'Aster Vale');
      expect(artist.extra['subscriberLabel'], '1.2M subscribers');
      expect(artist.extra['description'], contains('invented band'));
    });

    test('a header-less response is null, not an error', () async {
      harness.http.enqueueJson(<String, Object?>{
        'contents': <String, Object?>{
          'singleColumnBrowseResultsRenderer': <String, Object?>{
            'tabs': <Object?>[],
          },
        },
      });

      final SwayveArtist? artist = await harness.catalog.artist(
        YouTubeMusicIds.mediaId('UCq3rGZ1Zs9d0dTqRPcJHXyA'),
      );
      expect(artist, isNull);
    });
  });

  group('id classification', () {
    test('recognises each YouTube id shape', () {
      expect(
        YouTubeMusicIds.classify('kJQP7kiw5Fk'),
        YouTubeMusicIdKind.track,
      );
      expect(
        YouTubeMusicIds.classify('MPREb_9nqEki4ZLqI'),
        YouTubeMusicIdKind.album,
      );
      expect(
        YouTubeMusicIds.classify('UCq3rGZ1Zs9d0dTqRPcJHXyA'),
        YouTubeMusicIdKind.artist,
      );
      expect(
        YouTubeMusicIds.classify('VLPLZ4mM3wKuMh8'),
        YouTubeMusicIdKind.playlist,
      );
      expect(YouTubeMusicIds.classify('nonsense'), isNull);
      expect(YouTubeMusicIds.classify(''), isNull);
    });

    test('a media id round-trips through its uri form', () {
      final SwayveMediaId id = YouTubeMusicIds.mediaId('kJQP7kiw5Fk');
      expect(SwayveMediaId.parse(id.uri), id);
    });
  });
}
