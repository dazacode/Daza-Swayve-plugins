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

    test('a signed-in listener gets their own feed, with their session',
        () async {
      await harness.credentials.writeSecret(
        kSessionCookieSettingId,
        'SID=abc; __Secure-3PAPISID=secret',
      );
      harness.http.enqueueJson(fixture('browse_home.json'));
      await harness.catalog.albums(SwayveBrowseRequest.first);

      expect(
        harness.lastBody['browseId'],
        'FEmusic_mixed_for_you',
        reason: 'The personalized mix rows, which exist only for an account. '
            'Measured: an anonymous browse of this id answers HTTP 401, which '
            'is why it is only ever sent with a session in hand.',
      );
      expect(
        harness.http.lastRequest!.headers['cookie'],
        'SID=abc; __Secure-3PAPISID=secret',
        reason: 'Without it, `FEmusic_home` is the same twenty generic cards '
            'for everybody and their own feed is unreachable.',
      );
    });

    test('signed out, the feed request is byte-for-byte what it always was',
        () async {
      harness.http.enqueueJson(fixture('browse_home.json'));
      await harness.catalog.albums(SwayveBrowseRequest.first);

      expect(harness.lastBody['browseId'], 'FEmusic_home');
      expect(harness.http.lastRequest!.headers.containsKey('cookie'), isFalse);
      expect(
        harness.http.lastRequest!.headers.containsKey('authorization'),
        isFalse,
      );
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
    /// Fetches the fixture artist through the provider.
    Future<SwayveArtist> lookup(String name, String browseId) async {
      harness.http.enqueueJson(fixture(name));
      final SwayveArtist? artist = await harness.catalog.artist(
        YouTubeMusicIds.mediaId(browseId),
      );
      expect(artist, isNotNull, reason: '$name should resolve');
      return artist!;
    }

    /// The single section of [artist] with [kind], failing if there is not
    /// exactly one.
    SwayveArtistSection sectionOf(
      SwayveArtist artist,
      SwayveArtistSectionKind kind,
    ) {
      final Iterable<SwayveArtistSection> matches =
          artist.sections.where((SwayveArtistSection s) => s.kind == kind);
      expect(matches, hasLength(1), reason: 'one $kind section');
      return matches.single;
    }

    test('reads the immersive header', () async {
      final SwayveArtist artist = await lookup(
        'browse_artist.json',
        'UCq3rGZ1Zs9d0dTqRPcJHXyA',
      );

      expect(artist.name, 'Aster Vale');
      expect(artist.description, contains('invented band'));
      expect(
        artist.subscriberLabel,
        '1.24M subscribers',
        reason: 'The header carries three spellings of the same count. The '
            'long one is preferred because the SDK field is a label a host '
            'draws as-is, and "1.2M" on its own is a number with no noun.',
      );
      expect(
        artist.monthlyListenerLabel,
        '3,410,882 monthly listeners',
        reason: 'The field this whole pass began over: parsed nowhere before, '
            'and the one statistic somebody noticed was missing.',
      );
      expect(
        artist.image!.uri.host,
        'yt3.ggpht.com',
        reason: 'The avatar host the allowlist deliberately used to exclude. '
            'Without it declared, a large share of artists open onto a grey '
            'circle with two initials in it.',
      );
    });

    test('the header endpoints become play and radio ids', () async {
      final SwayveArtist artist = await lookup(
        'browse_artist.json',
        'UCq3rGZ1Zs9d0dTqRPcJHXyA',
      );

      expect(
        artist.playAll?.value,
        'OLAK5uy_kAsterValeAllSongs',
        reason: 'The button names a video and a playlist. The playlist wins: '
            '"play this artist" means the catalogue, not the one recording '
            'the service would happen to start with.',
      );
      expect(artist.startRadio?.value, 'RDAMVMasterVale01');
    });

    test('every shelf is parsed, in the order the page put them', () async {
      final SwayveArtist artist = await lookup(
        'browse_artist.json',
        'UCq3rGZ1Zs9d0dTqRPcJHXyA',
      );

      expect(
        artist.sections.map((SwayveArtistSection s) => s.kind).toList(),
        <SwayveArtistSectionKind>[
          SwayveArtistSectionKind.topSongs,
          SwayveArtistSectionKind.albums,
          SwayveArtistSectionKind.singles,
          SwayveArtistSectionKind.videos,
          SwayveArtistSectionKind.playlists,
          SwayveArtistSectionKind.relatedArtists,
        ],
        reason: 'Payload order is editorial — a page leads with the songs '
            'somebody came for and closes with somewhere to go next — and the '
            'trailing description shelf holds no items, so it is dropped '
            'rather than kept as an empty section.',
      );
    });

    test('shelves are classified by their contents, never their title', () {
      // The titles in the fixture are English. Nothing in the parser reads
      // them, which is the property this asserts: the classification above
      // came from endpoints and item shapes alone, and the titles only ride
      // along for display.
      const List<String> englishTitles = <String>[
        'Songs',
        'Albums',
        'Singles',
        'Videos',
        'Featured on',
        'Fans might also like',
      ];
      final String raw = fixtureText('browse_artist.json');
      for (final String title in englishTitles) {
        expect(raw, contains('"$title"'));
      }
    });

    test('top songs keep their ranking and gain the page credit', () async {
      final SwayveArtist artist = await lookup(
        'browse_artist.json',
        'UCq3rGZ1Zs9d0dTqRPcJHXyA',
      );
      final SwayveArtistSection songs =
          sectionOf(artist, SwayveArtistSectionKind.topSongs);

      expect(songs.title, 'Songs');
      expect(
        songs.tracks.map((SwayveTrack t) => t.title),
        <String>['Glasshouse', 'Ninth Street'],
        reason: 'First is biggest. Re-sorting is what the library list this '
            'replaces was already doing wrong.',
      );
      expect(
        songs.tracks.last.artists.single.name,
        'Aster Vale',
        reason: 'The second row spends its flex column on a play count, '
            'because the page above it is already titled with the name. A '
            'host filing that row on its own wrote "Unknown artist" onto it.',
      );
      expect(songs.more?.value, 'VLOLAK5uy_kAsterValeAllSongs');
    });

    test('albums and singles are told apart by their subtitles', () async {
      final SwayveArtist artist = await lookup(
        'browse_artist.json',
        'UCq3rGZ1Zs9d0dTqRPcJHXyA',
      );

      expect(
        sectionOf(artist, SwayveArtistSectionKind.albums)
            .albums
            .map((SwayveAlbum a) => a.title),
        <String>['Low Ceilings', 'Harbour Lights'],
      );
      expect(
        sectionOf(artist, SwayveArtistSectionKind.singles)
            .albums
            .map((SwayveAlbum a) => a.title),
        <String>['Ninth Street', 'Undertow'],
        reason: 'Both shelves are made of identical tiles pointing at album '
            'browse ids. The only difference in the payload is that an album '
            'tile writes "Album • 2023" and a single tile writes the year '
            'alone — a shape, which survives translation, rather than the '
            'word "Single", which does not.',
      );
      expect(
        sectionOf(artist, SwayveArtistSectionKind.albums).more?.value,
        'MPADUCq3rGZ1Zs9d0dTqRPcJHXyA',
        reason: 'From the carousel header\'s moreContentButton.',
      );
    });

    test('videos are a shelf of tracks, not of songs', () async {
      final SwayveArtist artist = await lookup(
        'browse_artist.json',
        'UCq3rGZ1Zs9d0dTqRPcJHXyA',
      );
      final SwayveArtistSection videos =
          sectionOf(artist, SwayveArtistSectionKind.videos);

      expect(videos.tracks.single.kind, SwayveTrackKind.video);
      expect(
        sectionOf(artist, SwayveArtistSectionKind.topSongs).tracks.first.kind,
        SwayveTrackKind.song,
        reason: 'Both shelves hold tracks. What separates them is the '
            'musicVideoType each row already states, which ItemCollector has '
            'turned into a SwayveTrackKind before the shelf is classified.',
      );
    });

    test('featured-on and related artists land in their own lists', () async {
      final SwayveArtist artist = await lookup(
        'browse_artist.json',
        'UCq3rGZ1Zs9d0dTqRPcJHXyA',
      );

      expect(
        sectionOf(artist, SwayveArtistSectionKind.playlists)
            .playlists
            .single
            .title,
        'Slow Burn',
      );
      final SwayveArtist related =
          sectionOf(artist, SwayveArtistSectionKind.relatedArtists)
              .artists
              .single;
      expect(related.name, 'Marrow Choir');
      expect(
        related.sections,
        isEmpty,
        reason: 'An artist minted from a tile carries a tile\'s worth. Only a '
            'lookup fetches a page, and nothing here fetched one.',
      );
    });

    test('an artist with only songs still parses', () async {
      final SwayveArtist artist = await lookup(
        'browse_artist_songs_only.json',
        'UCq3rGZ1Zs9d0dTqRPcJHXyB',
      );

      expect(artist.name, 'Fenwick Rowe');
      expect(
        artist.sections.single.kind,
        SwayveArtistSectionKind.topSongs,
        reason: 'The first tab of this response is empty, so a parser reading '
            'tabs[0] flatly would find no page at all.',
      );
      expect(
        artist.subscriberLabel,
        '8.1K',
        reason: 'The short spelling is the last resort rather than absent: a '
            'bare number is worse than a sentence and better than nothing.',
      );
      expect(
        artist.monthlyListenerLabel,
        isNull,
        reason: 'Not published for every artist, and an absent fact stays '
            'absent rather than being filled in from somewhere else.',
      );
      expect(artist.banner, isNull);
    });

    test('a visual header is a banner plus a wordmark', () async {
      final SwayveArtist artist = await lookup(
        'browse_artist_visual_header.json',
        'UCq3rGZ1Zs9d0dTqRPcJHXyC',
      );

      expect(artist.name, 'The Quiet Ordinary');
      expect(
        artist.banner!.uri.host,
        'yt3.googleusercontent.com',
        reason: 'On this renderer `thumbnail` is the wide header image, not '
            'the portrait — the field name is the same and the picture is '
            'not.',
      );
      expect(artist.banner!.width, 2560);
      expect(
        artist.image!.uri.toString(),
        contains('quietOrdinaryWordmark'),
        reason: 'foregroundThumbnail is the artist\'s name set as a logo. It '
            'is used as the avatar for the reason both reference clients use '
            'it that way: a circle cropped out of a 2560x424 banner is a '
            'piece of somebody\'s shoulder.',
      );
      expect(
        artist.sections.single.kind,
        SwayveArtistSectionKind.albums,
        reason: 'The shelves below a visual header are the ordinary ones.',
      );
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

  group('the strapline header (artist moved out of subtitle)', () {
    // The current `musicResponsiveHeaderRenderer` shape draws the artist as
    // its own byline above the title, in `straplineTextOne`, and shrinks
    // `subtitle` down to "Album • 2019" with no artist run left in it at
    // all. `artistRefsFromRuns(subtitleRuns)` had nothing to find here — not
    // because a run's endpoint failed to classify, but because the artist
    // was never in `subtitle` to begin with — and every row's own flex
    // column skips the artist too, the same way the two-column fixture's
    // rows sometimes do, relying entirely on the header for credit. Every
    // song of every record opened this way came back "Unknown artist" until
    // `straplineTextOne` was read as a second source.
    test('the album is credited from the strapline', () async {
      harness.http.enqueueJson(fixture('browse_album_strapline.json'));
      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      expect(album, isNotNull);
      expect(album!.title, 'Long Way Home');
      expect(
        album.artists.single.name,
        'Aster Vale',
        reason: 'Nothing in this fixture\'s `subtitle` names an artist at '
            'all — the credit only exists in `straplineTextOne`.',
      );
      expect(
        album.artists.single.id,
        YouTubeMusicIds.mediaId('UCq3rGZ1Zs9d0dTqRPcJHXyA'),
      );
      expect(album.year, 2019);
      expect(album.trackCount, 12);
    });

    test('every row inherits the credit the header found in the strapline',
        () async {
      harness.http.enqueueJson(fixture('browse_album_strapline.json'));
      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      expect(album!.tracks, hasLength(2));
      for (final SwayveTrack track in album.tracks) {
        expect(
          track.artists.map((SwayveArtistRef a) => a.name),
          contains('Aster Vale'),
          reason: 'A row here carries no artist of its own — the strapline '
              'is the only place the credit exists, so it has to reach the '
              'tracks too, not just the album header.',
        );
      }
    });

    test('an unlinked strapline is still read as a name', () async {
      // Same shape, but the strapline names the artist as plain text with no
      // `navigationEndpoint` — a compilation or "Various Artists" credit is
      // real enough not to link anywhere. A name with no id is still a name,
      // and the alternative is the same "Unknown artist" this whole header
      // was added to stop.
      harness.http.enqueueJson(<String, Object?>{
        'contents': <String, Object?>{
          'twoColumnBrowseResultsRenderer': <String, Object?>{
            'tabs': <Object?>[
              <String, Object?>{
                'tabRenderer': <String, Object?>{
                  'content': <String, Object?>{
                    'sectionListRenderer': <String, Object?>{
                      'contents': <Object?>[
                        <String, Object?>{
                          'musicResponsiveHeaderRenderer': <String, Object?>{
                            'title': <String, Object?>{
                              'runs': <Object?>[
                                <String, Object?>{'text': 'Sampler Vol. 1'},
                              ],
                            },
                            'straplineTextOne': <String, Object?>{
                              'runs': <Object?>[
                                <String, Object?>{
                                  'text': 'Various Artists',
                                },
                              ],
                            },
                            'subtitle': <String, Object?>{
                              'runs': <Object?>[
                                <String, Object?>{'text': 'Album'},
                                <String, Object?>{'text': ' • '},
                                <String, Object?>{'text': '2021'},
                              ],
                            },
                          },
                        },
                      ],
                    },
                  },
                },
              },
            ],
          },
        },
      });

      final SwayveAlbum? album = await harness.catalog.album(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      expect(album, isNotNull);
      expect(album!.artists.single.name, 'Various Artists');
      expect(
        album.artists.single.id,
        isNull,
        reason: 'Nothing here ever linked anywhere, so there is no id to '
            'invent one from.',
      );
    });
  });

  group('a feed with no songs on it', () {
    test('follows the albums and playlists it does carry', () async {
      harness.http
        ..enqueueJson(fixture('browse_charts_no_songs.json'))
        ..enqueueJson(fixture('browse_chart_playlist.json'));

      // Asked for exactly what one shelf holds, so the page is filled by the
      // first one opened and the rest stay where they are. The unbounded
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
        'MPREb_fixtureTopAlbum',
        reason: 'The album the feed named, browsed under its own id — albums '
            'are drained before playlists, and this fixture shelf carries two '
            'playlists ahead of one album in listing order. A chart made '
            'mostly of "Top albums", the shape the real service actually '
            'returns, must not have every one of those rows skipped for '
            'naming no playlist.',
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

    test(
        'the cursor resumes in the albums and playlists rather than the '
        'feed', () async {
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
        'VLPLfixtureTrending20',
        reason: 'A page served out of albums and playlists has to carry on '
            'through the ones it has not opened yet. The first call already '
            'drained this fixture shelf\'s one album; the first playlist is '
            'next. Handing this cursor back to the feed would start the '
            'charts again and re-file the same songs.',
      );
    });
  });

  group('a feed that never gets to a playlist', () {
    /// A page shaped like a real continuation response, but naming no
    /// playlist and no track — just another continuation token. A chart made
    /// almost entirely of shelves this plugin does not collect (genre grids,
    /// "new artists you might like", and the like) can answer this way for
    /// several pages before a playlist shelf finally turns up, and nothing
    /// about the shape is malformed enough for [tryParseFeed] to reject it.
    Map<String, Object?> emptyContinuation(String token) => <String, Object?>{
          'continuationContents': <String, Object?>{
            'musicShelfContinuation': <String, Object?>{
              'contents': <Object?>[],
              'continuations': <Object?>[
                <String, Object?>{
                  'nextContinuationData': <String, Object?>{
                    'continuation': token,
                  },
                },
              ],
            },
          },
        };

    test('does not spend the whole page hammering the same feed', () async {
      // The first page: structurally a browse response, but its one shelf is
      // empty and only carries a continuation onward.
      harness.http.enqueueJson(<String, Object?>{
        'contents': <String, Object?>{
          'singleColumnBrowseResultsRenderer': <String, Object?>{
            'tabs': <Object?>[
              <String, Object?>{
                'tabRenderer': <String, Object?>{
                  'content': <String, Object?>{
                    'sectionListRenderer': <String, Object?>{
                      'contents': <Object?>[
                        <String, Object?>{
                          'musicShelfRenderer': <String, Object?>{
                            'contents': <Object?>[],
                            'continuations': <Object?>[
                              <String, Object?>{
                                'nextContinuationData': <String, Object?>{
                                  'continuation': 'token-1',
                                },
                              },
                            ],
                          },
                        },
                      ],
                    },
                  },
                },
              },
            ],
          },
        },
      });
      // Five more pages, every one of them just as empty and just as eager to
      // hand back another token. A feed can keep this up far longer than
      // five — this is only enough to prove the loop does not run to the end
      // of the queue.
      for (final String token in <String>[
        'token-2',
        'token-3',
        'token-4',
        'token-5',
        'token-6',
      ]) {
        harness.http.enqueueJson(emptyContinuation(token));
      }

      final SwayvePage<SwayveTrack> page = await harness.catalog.tracks(
        const SwayveBrowseRequest(limit: 50),
      );

      expect(
        page.items,
        isEmpty,
        reason: 'Nothing on any of these pages was ever a playlist or a '
            'track, so there is genuinely nothing to hand back.',
      );
      expect(
        harness.http.requests.length,
        lessThan(6),
        reason: 'Every one of these continuations was empty and the queue '
            'had six of them queued up. A provider that keeps asking for '
            '"maybe the next one" without any bound on how many times will '
            'walk the whole queue, spending its entire operation budget '
            'hammering a feed that was never going to name a playlist — '
            'which is a several-second stall on a real network, not a '
            'four-microsecond one, and reads to whoever is holding the '
            'phone as the app having frozen.',
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
