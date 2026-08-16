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

    test('limit never costs the page items the cursor has passed', () async {
      harness.http.enqueueJson(fixture('browse_home.json'));
      final SwayvePage<SwayveAlbum> page = await harness.catalog.albums(
        const SwayveBrowseRequest(limit: 0),
      );

      expect(
        page.items,
        hasLength(1),
        reason: 'One response is many shelves and the continuation token it '
            'carries points past all of them, so an item dropped here is an '
            'item nothing ever asks for again — the next page resumes after '
            'it. A host that cannot hold them all can take what it wants off '
            'the front; discarding them here is a decision nothing can undo, '
            'and it is what left albums with songs missing.',
      );
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

    test('a video id that looks like a browse prefix is still a track', () {
      // Every one of these is eleven base64url characters, which is what a
      // video id is, and each begins with the letters a browse id is
      // namespaced by. Classified by prefix they came out as playlists and
      // artists, and the consequences were all silent: the stream provider
      // refused to play them for "not being a track", and the artwork provider
      // spent a browse request on an id no browse resolves.
      for (final String id in const <String>[
        'PLxKq2n8Qm4',
        'RDh1sT0pQwZ',
        'UCn3dK9wVbX',
        'VLm2QpX7nRt',
      ]) {
        expect(
          YouTubeMusicIds.classify(id),
          YouTubeMusicIdKind.track,
          reason: '$id is eleven characters, so it is a video id. No browse '
              'id is eleven characters — release ids are seventeen, channel '
              'ids twenty-four, playlist ids thirty-four and up — so the '
              'shape is decisive and the prefix is not.',
        );
      }
    });
  });

  group('the two-column browse response', () {
    test('an album lists its songs from the second column', () async {
      harness.http.enqueueJson(fixture('browse_album_two_column.json'));
      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      expect(album, isNotNull);
      expect(album!.title, 'Long Way Home');
      expect(
        album.tracks.map((SwayveTrack t) => t.title),
        <String>['Nightdrive', 'Harbour Lights'],
        reason: 'YouTube Music now describes a release in one column and lists '
            'its songs in the other. Reading only the first gave an album that '
            'looked healthy — right title, right sleeve, right year — and '
            'arrived with no tracks at all, so the page drew whatever songs a '
            'search had happened to drag back and said nothing about the rest.',
      );
    });

    test('the header is found in the first column', () async {
      harness.http.enqueueJson(fixture('browse_album_two_column.json'));
      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      expect(album!.artists.single.name, 'Aster Vale');
      expect(album.year, 2019);
      expect(album.trackCount, 12);
    });

    test('a row with no credit of its own is credited to the record', () async {
      harness.http.enqueueJson(fixture('browse_album_two_column.json'));
      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      for (final SwayveTrack track in album!.tracks) {
        expect(
          track.artists.map((SwayveArtistRef a) => a.name),
          contains('Aster Vale'),
          reason: 'The two-column layout gives each song a title, a running '
              'time and an empty second column — the artist is written once, '
              'in the header above them. A host filing those rows on their own '
              'had nobody to credit them to and wrote "Unknown artist" onto '
              'every song of every record opened this way.',
        );
      }
    });
  });

  group('a feed with no songs on it', () {
    test('follows the playlists it does carry', () async {
      harness.http
        ..enqueueJson(fixture('browse_charts_no_songs.json'))
        ..enqueueJson(fixture('browse_chart_playlist.json'));

      // Asked for exactly what one playlist holds, so the page is filled by
      // the first one opened and the second stays where it is. The unbounded
      // request is a different test — see the cursor one below — and mixing
      // the two here would make this assert the paging as well as the hop.
      final SwayvePage<SwayveTrack> page = await harness.catalog.tracks(
        const SwayveBrowseRequest(limit: 2),
      );

      expect(
        page.items.map((SwayveTrack t) => t.title),
        <String>['Reap What You Sow', 'Petal'],
        reason: 'Signed out, the charts feed is about a hundred rows and not '
            'one of them carries a video id — the shelves are top albums, top '
            'artists and playlists. So this returned an empty page, always, '
            'and the only thing that ever put a song in a plugin library was '
            'somebody typing a search.',
      );
      expect(
        harness.lastBody['browseId'],
        'VLPLfixtureTrending20',
        reason: 'The first playlist the feed named, browsed under its VL id. '
            'The album on the same shelf is not a playlist and must not be '
            'browsed as though it were.',
      );
    });

    test('the songs it finds that way arrive whole', () async {
      harness.http
        ..enqueueJson(fixture('browse_charts_no_songs.json'))
        ..enqueueJson(fixture('browse_chart_playlist.json'));

      // Asked for exactly what one playlist holds, so the page is filled by
      // the first one opened and the second stays where it is. The unbounded
      // request is a different test — see the cursor one below — and mixing
      // the two here would make this assert the paging as well as the hop.
      final SwayvePage<SwayveTrack> page = await harness.catalog.tracks(
        const SwayveBrowseRequest(limit: 2),
      );

      final SwayveTrack first = page.items.first;
      expect(first.artists.single.name, 'Pooh Shiesty');
      expect(first.duration, const Duration(minutes: 3, seconds: 38));
    });

    test('a feed that does carry songs is served straight through', () async {
      harness.http.enqueueJson(fixture('browse_home.json'));
      final SwayvePage<SwayveTrack> page = await harness.catalog.tracks(
        SwayveBrowseRequest.first,
      );

      expect(page.items.single.title, 'Nightdrive');
      expect(
        harness.http.requests,
        hasLength(1),
        reason: 'The playlist hop is a fallback, not the design. A feed with a '
            'song shelf on it must not cost an extra round trip.',
      );
    });

    test('the cursor resumes in the playlists rather than the feed', () async {
      harness.http
        ..enqueueJson(fixture('browse_charts_no_songs.json'))
        ..enqueueJson(fixture('browse_chart_playlist.json'));
      final SwayvePage<SwayveTrack> first = await harness.catalog.tracks(
        const SwayveBrowseRequest(limit: 1),
      );

      expect(first.cursor, isNotNull);
      expect(first.hasMore, isTrue);

      harness.http.enqueueJson(fixture('browse_chart_playlist.json'));
      await harness.catalog.tracks(
        SwayveBrowseRequest(cursor: first.cursor, limit: 2),
      );

      expect(
        harness.lastBody['browseId'],
        'VLPLfixtureDailyTop',
        reason: 'A page served out of playlists has to carry on through the '
            'ones it has not opened yet. Handing this cursor back to the feed '
            'would start the charts again and re-file the same songs.',
      );
    });
  });

  group('telling a song from an upload', () {
    test('an art track is a song', () async {
      harness.http
        ..enqueueJson(fixture('browse_charts_no_songs.json'))
        ..enqueueJson(fixture('browse_chart_playlist.json'));
      final SwayvePage<SwayveTrack> page = await harness.catalog.tracks(
        const SwayveBrowseRequest(limit: 2),
      );

      expect(
        page.items.firstWhere((SwayveTrack t) => t.title == 'Petal').kind,
        SwayveTrackKind.song,
        reason: 'An "art track" is the audio-only rendition YouTube Music '
            'generates for a licensed release — a still sleeve and the '
            'recording, which is a song by any reading.',
      );
    });

    test('an official music video is not', () async {
      harness.http
        ..enqueueJson(fixture('browse_charts_no_songs.json'))
        ..enqueueJson(fixture('browse_chart_playlist.json'));
      final SwayvePage<SwayveTrack> page = await harness.catalog.tracks(
        const SwayveBrowseRequest(limit: 2),
      );

      expect(
        page.items
            .firstWhere((SwayveTrack t) => t.title == 'Reap What You Sow')
            .kind,
        SwayveTrackKind.video,
        reason: 'This distinction used to be drawn by which search shelf a row '
            'arrived on, which is no help at all to a browse — so every row '
            'from every feed, playlist and album was filed as a song, and a '
            'host offering to separate the two had nothing to separate them '
            'by.',
      );
    });
  });
}
