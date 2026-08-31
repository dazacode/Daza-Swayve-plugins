import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';
import 'package:youtube_music/youtube_music.dart';

import 'support.dart';

/// The playlist fixtures are real responses, trimmed.
///
/// `browse_playlist_curated.json` is a live browse of the editorial playlist
/// `RDCLAK5uy_lvHI2Z7dSfpD5g8wvmePjWPfYwq5IgkLo` — cut from a hundred rows to
/// eight, keeping the continuation — and `browse_playlist_community.json` is
/// the community playlist `PLCFVJey7ZapJ4EgJZQ7HXLv3NuOblQCJt`, cut from
/// twenty to four. **Both were fetched with no session at all**, which is the
/// fact section B turns on: curated and community playlists browse
/// anonymously, so a signed-out listener is not shown an empty library.
void main() {
  late PluginHarness harness;

  const String curatedId = 'RDCLAK5uy_lvHI2Z7dSfpD5g8wvmePjWPfYwq5IgkLo';
  const String communityId = 'PLCFVJey7ZapJ4EgJZQ7HXLv3NuOblQCJt';
  const String cookie = 'SID=abc; __Secure-3PAPISID=secret';

  setUp(() async {
    harness = await PluginHarness.start();
  });

  tearDown(() => harness.stop());

  group('the VL prefix', () {
    test('is added exactly once, however many times it is applied', () {
      expect(YouTubeMusicIds.playlistBrowseId(communityId), 'VL$communityId');
      expect(
        YouTubeMusicIds.playlistBrowseId('VL$communityId'),
        'VL$communityId',
        reason: 'A browseEndpoint in a response arrives already prefixed.',
      );
      expect(
        YouTubeMusicIds.playlistBrowseId('VLVL$communityId'),
        'VL$communityId',
        reason: 'Strip, then add. A naive prepend produces VLVL…, which '
            'InnerTube answers with a 400 — and this is the exact shape a '
            'round trip through a SwayveMediaId can produce.',
      );
      expect(
        YouTubeMusicIds.playlistBrowseId(
          YouTubeMusicIds.playlistBrowseId(curatedId),
        ),
        'VL$curatedId',
        reason: 'Idempotent, which is the property every call site relies on.',
      );
      expect(YouTubeMusicIds.playlistBrowseId('OLAK5uy_abc'), 'VLOLAK5uy_abc');
      expect(YouTubeMusicIds.playlistBrowseId('LM'), 'VLLM');
      expect(YouTubeMusicIds.barePlaylistId('VLVLPL123'), 'PL123');
    });

    test('every shape these ids arrive in classifies as a playlist', () {
      for (final String id in <String>[
        curatedId,
        'VL$curatedId',
        communityId,
        'VL$communityId',
        'OLAK5uy_kShQBl1_4tPuLCVEsFI4tqOgFxb2Zvt2s',
      ]) {
        expect(
          YouTubeMusicIds.classify(id),
          YouTubeMusicIdKind.playlist,
          reason: '$id must be openable without special-casing.',
        );
      }
    });
  });

  group('opening a playlist', () {
    test('a curated playlist parses its header and its rows', () async {
      harness.http.enqueueJson(fixture('browse_playlist_curated.json'));
      final SwayvePlaylist? playlist = await harness.playlists.playlist(
        YouTubeMusicIds.mediaId(curatedId),
      );

      expect(harness.lastBody['browseId'], 'VL$curatedId');
      expect(playlist, isNotNull);
      expect(playlist!.title, "'80s Rock");
      expect(
        playlist.trackCount,
        132,
        reason: 'Read off `secondSubtitle` ("132 songs • 7+ hours"), not off '
            'the eight rows this trimmed fixture happens to carry.',
      );
      expect(playlist.description, isNotNull);
      expect(
        playlist.ownerName,
        isNull,
        reason: 'A curated playlist links nobody. Crediting it to the first '
            'subtitle segment would credit it to the localized word '
            '"Playlist".',
      );
      expect(playlist.extra['browseId'], 'VL$curatedId');
    });

    test('a curated playlist opens anonymously', () async {
      harness.http.enqueueJson(fixture('browse_playlist_curated.json'));
      final SwayvePage<SwayveTrack> page =
          await harness.playlists.playlistTracks(
        YouTubeMusicIds.mediaId(curatedId),
        SwayveBrowseRequest.first,
      );

      expect(page.items, hasLength(8));
      expect(page.items.first.title, isNotEmpty);
      expect(page.items.first.artists, isNotEmpty);
      expect(page.items.first.duration, isNotNull);
      expect(
        page.cursor,
        isNotNull,
        reason: 'The real response ends its shelf with a '
            'continuationItemRenderer, which the existing feed parser already '
            'reads.',
      );
      expect(
        harness.http.lastRequest!.headers.containsKey('cookie'),
        isFalse,
        reason: 'No session was stored, so none is sent — measured: a '
            'hundred-track editorial playlist answers 200 anonymously.',
      );
    });

    test('a community PL… playlist parses through the same path', () async {
      harness.http.enqueueJson(fixture('browse_playlist_community.json'));
      final SwayvePage<SwayveTrack> page =
          await harness.playlists.playlistTracks(
        YouTubeMusicIds.mediaId(communityId),
        SwayveBrowseRequest.first,
      );

      expect(harness.lastBody['browseId'], 'VL$communityId');
      expect(page.items, hasLength(4));
      expect(
        page.cursor,
        isNull,
        reason: 'This playlist is twenty tracks and the service sends them in '
            'one go, so there is nothing to page.',
      );
    });

    test('an already-prefixed id is not prefixed again', () async {
      harness.http.enqueueJson(fixture('browse_playlist_community.json'));
      await harness.playlists.playlistTracks(
        YouTubeMusicIds.mediaId('VL$communityId'),
        SwayveBrowseRequest.first,
      );
      expect(
        harness.lastBody['browseId'],
        'VL$communityId',
        reason: 'Not VLVL…, which is the 400 this normalization exists for.',
      );
    });

    test('a cursor goes straight back to the service', () async {
      harness.http.enqueueJson(fixture('browse_playlist_community.json'));
      await harness.playlists.playlistTracks(
        YouTubeMusicIds.mediaId(communityId),
        const SwayveBrowseRequest(cursor: 'next-page'),
      );
      expect(harness.lastBody['continuation'], 'next-page');
    });

    test('a private playlist gets the stored session', () async {
      await harness.credentials.writeSecret(kSessionCookieSettingId, cookie);
      harness.http.enqueueJson(fixture('browse_playlist_community.json'));
      await harness.playlists.playlistTracks(
        YouTubeMusicIds.mediaId(communityId),
        SwayveBrowseRequest.first,
      );
      expect(harness.http.lastRequest!.headers['cookie'], cookie);
    });

    test('an id of the wrong kind is an empty page, not an exception',
        () async {
      final SwayvePage<SwayveTrack> page =
          await harness.playlists.playlistTracks(
        YouTubeMusicIds.mediaId('dQw4w9WgXcQ'),
        SwayveBrowseRequest.first,
      );
      expect(page.items, isEmpty);
      expect(harness.http.requests, isEmpty);
    });
  });

  group('listing playlists', () {
    test('signed out, the curated home shelves answer', () async {
      harness.http.enqueueJson(fixture('browse_charts_no_songs.json'));
      final SwayvePage<SwayvePlaylist> page = await harness.playlists.playlists(
        SwayveBrowseRequest.first,
      );

      expect(harness.lastBody['browseId'], 'FEmusic_home');
      expect(page.items, isNotEmpty);
      expect(page.items.first.title, isNotEmpty);
    });

    test('signed in, the listener\'s own playlists answer', () async {
      await harness.credentials.writeSecret(kSessionCookieSettingId, cookie);
      harness.http.enqueueJson(fixture('browse_home.json'));
      await harness.playlists.playlists(SwayveBrowseRequest.first);

      expect(harness.lastBody['browseId'], 'FEmusic_liked_playlists');
      expect(harness.http.lastRequest!.headers['cookie'], cookie);
    });

    test('a stale cookie is auth-required, not an empty library', () async {
      await harness.credentials.writeSecret(kSessionCookieSettingId, cookie);
      harness.http.enqueueJson(fixture('liked_playlists_signed_out.json'));

      await expectLater(
        harness.playlists.playlists(SwayveBrowseRequest.first),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
    });

    test('the same placeholder never fails the curated source', () async {
      // Signed out, the curated feed is what is asked for — so even a body
      // shaped like the sign-in placeholder is read as a feed with nothing in
      // it rather than as a reason to demand a sign-in nobody needs.
      harness.http.enqueueJson(fixture('liked_playlists_signed_out.json'));
      final SwayvePage<SwayvePlaylist> page = await harness.playlists.playlists(
        SwayveBrowseRequest.first,
      );
      expect(page.items, isEmpty);
    });

    test('sort picks the source, the same way the catalog provider does', () {
      expect(
        YouTubeMusicPlaylistProvider.feedFor(null, signedIn: false),
        'FEmusic_home',
      );
      expect(
        YouTubeMusicPlaylistProvider.feedFor(null, signedIn: true),
        'FEmusic_liked_playlists',
      );
      expect(
        YouTubeMusicPlaylistProvider.feedFor(
          SwayveSortOrder.recent,
          signedIn: true,
        ),
        'FEmusic_new_releases',
      );
      expect(
        YouTubeMusicPlaylistProvider.feedFor(
          SwayveSortOrder.popular,
          signedIn: false,
        ),
        'FEmusic_charts',
      );
      expect(
        YouTubeMusicPlaylistProvider.feedFor(
          SwayveSortOrder.alphabetical,
          signedIn: false,
        ),
        'FEmusic_moods_and_genres',
      );
    });
  });

  group('moods and genres', () {
    test('yields chips with params, because it yields no playlists', () {
      final List<MoodChip> chips = parseMoodChips(
        fixtureMap('browse_moods_and_genres.json'),
      );

      expect(chips, isNotEmpty);
      expect(chips.first.title, 'Chill');
      for (final MoodChip chip in chips) {
        expect(chip.title, isNotEmpty);
        expect(
          chip.params,
          isNotEmpty,
          reason: 'Every chip carries the same browse id, '
              'FEmusic_moods_and_genres_category. The params are the only '
              'thing that tells one category from another — which is why a '
              'chip must not be minted as a SwayvePlaylist, whose ids would '
              'then all collide.',
        );
      }
      expect(
        chips.map((MoodChip chip) => chip.params).toSet(),
        hasLength(chips.length),
      );
    });

    test('a body with no chips is an empty list, not an exception', () {
      expect(parseMoodChips(const <String, Object?>{}), isEmpty);
      expect(parseMoodChips(fixtureMap('browse_home.json')), isEmpty);
    });

    test('the directory is opened one category at a time', () async {
      harness.http
        ..enqueueJson(fixture('browse_moods_and_genres.json'))
        ..enqueueJson(fixture('browse_charts_no_songs.json'))
        ..enqueueJson(fixture('browse_charts_no_songs.json'));

      final SwayvePage<SwayvePlaylist> page = await harness.playlists.playlists(
        const SwayveBrowseRequest(sort: SwayveSortOrder.alphabetical),
      );

      expect(
        harness.http.requests,
        hasLength(3),
        reason: 'One for the directory, then two categories — bounded for the '
            'same reason the catalog provider bounds its own shelf-opening: '
            'they share one operation budget.',
      );
      expect(harness.bodyAt(0)['browseId'], 'FEmusic_moods_and_genres');
      expect(
        harness.bodyAt(1)['browseId'],
        'FEmusic_moods_and_genres_category',
      );
      expect(harness.bodyAt(1)['params'], isNotEmpty);
      expect(page.items, isNotEmpty);
      expect(
        page.cursor,
        isNotNull,
        reason: 'Eight chips in this fixture and two opened, so the rest go '
            'into the cursor and "load more" carries on down the list.',
      );

      harness.http
        ..enqueueJson(fixture('browse_charts_no_songs.json'))
        ..enqueueJson(fixture('browse_charts_no_songs.json'));
      await harness.playlists.playlists(
        SwayveBrowseRequest(
          sort: SwayveSortOrder.alphabetical,
          cursor: page.cursor,
        ),
      );
      expect(
        harness.bodyAt(3)['browseId'],
        'FEmusic_moods_and_genres_category',
        reason: 'The second page resumes at the next chip rather than '
            'browsing the directory again.',
      );
    });
  });
}
