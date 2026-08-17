import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late PluginHarness harness;

  setUp(() async {
    harness = await PluginHarness.start(timeouts: fastTimeouts);
  });
  tearDown(() => harness.stop());

  test('a single-kind query hits only that endpoint', () async {
    harness.enqueueClientId();
    harness.http.enqueueText(fixtureText('search_tracks.json'));

    final SwayveSearchResult result = await harness.search.search(
      const SwayveSearchQuery(text: 'test', kinds: {SwayveSearchKind.track}),
    );

    expect(result.tracks, hasLength(2));
    expect(result.tracks.first.title, 'First Result');
    expect(result.tracks.first.id.value, 't1001');
    expect(result.tracks[1].explicit, isTrue);
    expect(result.tracks[1].availability.downloadable, isTrue);
    expect(result.albums, isEmpty);
    expect(result.artists, isEmpty);
    expect(result.playlists, isEmpty);

    final Uri requested = harness.requestedUrls.last;
    expect(requested.path, '/search/tracks');
    expect(requested.queryParameters['q'], 'test');
  });

  test('a bad row is skipped rather than failing the whole search', () async {
    harness.enqueueClientId();
    harness.http.enqueueText(fixtureText('search_tracks.json'));

    final SwayveSearchResult result = await harness.search.search(
      const SwayveSearchQuery(text: 'test', kinds: {SwayveSearchKind.track}),
    );

    // The fixture has three collection entries; the third has no id and is
    // dropped, not fatal.
    expect(result.tracks, hasLength(2));
  });

  test('empty text short-circuits without a request', () async {
    final SwayveSearchResult result = await harness.search.search(
      const SwayveSearchQuery(text: '   '),
    );
    expect(result, SwayveSearchResult.empty);
    expect(harness.http.requests, isEmpty);
  });

  test('album and playlist kinds split by is_album', () async {
    harness.enqueueClientId();
    harness.http
      ..enqueueText(fixtureText('search_albums.json'))
      ..enqueueText(fixtureText('search_playlists.json'));

    final SwayveSearchResult result = await harness.search.search(
      const SwayveSearchQuery(
        text: 'test',
        kinds: {SwayveSearchKind.album, SwayveSearchKind.playlist},
      ),
    );

    expect(result.albums, hasLength(1));
    expect(result.albums.single.title, 'A Real Album');
    expect(
      result.albums.single.tracks,
      isEmpty,
      reason: 'listing results carry no track list per the SDK contract',
    );

    // search_playlists.json has one real playlist and one mislabeled
    // is_album:true entry, which must NOT appear as a playlist here.
    expect(result.playlists, hasLength(1));
    expect(result.playlists.single.title, 'A Plain Playlist');
  });

  test('a mixed-kind query fans out to one request per kind', () async {
    harness.enqueueClientId();
    harness.http
      ..enqueueText(fixtureText('search_tracks.json'))
      ..enqueueText(fixtureText('search_albums.json'))
      ..enqueueText(fixtureText('search_users.json'))
      ..enqueueText(fixtureText('search_playlists.json'));

    final SwayveSearchResult result = await harness.search.search(
      const SwayveSearchQuery(text: 'test'),
    );

    expect(result.tracks, isNotEmpty);
    expect(result.albums, isNotEmpty);
    expect(result.artists, isNotEmpty);
    expect(result.playlists, isNotEmpty);

    final Iterable<Uri> apiCalls =
        harness.requestedUrls.where((u) => u.host == 'api-v2.soundcloud.com');
    expect(
      apiCalls.map((u) => u.path),
      unorderedEquals(<String>[
        '/search/tracks',
        '/search/albums',
        '/search/users',
        '/search/playlists',
      ]),
    );
  });

  test('the multi-shelf cursor round-trips and pages each shelf independently', () async {
    harness.enqueueClientId();
    harness.http.enqueueText(fixtureText('search_tracks.json'));

    final SwayveSearchResult first = await harness.search.search(
      const SwayveSearchQuery(text: 'test', kinds: {SwayveSearchKind.track}),
    );
    expect(first.hasMore, isTrue);
    expect(first.cursor, startsWith('sc2|'));

    harness.http.enqueueJson(<String, Object?>{
      'collection': <Object?>[
        {
          'id': 1003,
          'kind': 'track',
          'title': 'Page Two',
          'user': {'id': 2001, 'kind': 'user', 'username': 'ArtistOne'},
        },
      ],
      'next_href': null,
    });

    final SwayveSearchResult second = await harness.search.search(
      SwayveSearchQuery(
        text: 'test',
        kinds: const {SwayveSearchKind.track},
        cursor: first.cursor,
      ),
    );

    expect(second.tracks.single.title, 'Page Two');
    expect(second.hasMore, isFalse);
    // The second call followed the captured next_href directly, not a fresh
    // first-page request.
    final Uri followed = harness.requestedUrls.last;
    expect(followed.queryParameters['offset'], '20');
  });

  test('limit is a ceiling per kind, sent on the wire', () async {
    harness.enqueueClientId();
    harness.http.enqueueText(fixtureText('search_tracks.json'));

    await harness.search.search(
      const SwayveSearchQuery(
        text: 'test',
        kinds: {SwayveSearchKind.track},
        limit: 7,
      ),
    );

    final Uri requested = harness.requestedUrls.last;
    expect(requested.queryParameters['limit'], '7');
  });
}
