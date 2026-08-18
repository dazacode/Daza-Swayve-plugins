// Search: normalization, the query contract, and cancellation.
//
// Every test here reaches the provider the way the host does — by taking the
// one the plugin registered during `initialize` — rather than constructing it
// directly. That way a plugin that forgets to register something fails these
// tests too.

import 'package:swayve_plugin_example/example.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeSwayvePluginContext context;

  setUp(() {
    context = FakeSwayvePluginContext();
  });

  tearDown(() => context.close());

  Future<SwayveSearchProvider> provider({ExampleCatalogue? catalogue}) async {
    await ExamplePlugin(catalogue: catalogue).initialize(context);
    return context.searchProviders.single;
  }

  test('results are normalized SDK models, not raw fixture rows', () async {
    final search = await provider();

    final result = await search.search(
      const SwayveSearchQuery(text: 'iron in the water'),
    );

    final track = result.tracks.single;
    expect(track.title, 'Iron in the Water');
    // Ids carry the minting plugin, so the host can route a later request back
    // to us without knowing anything else about the item.
    expect(track.id.pluginId, examplePluginId);
    expect(track.id.uri, startsWith('swayve://$examplePluginId/'));
    // Seconds became a Duration, and a one-string credit became refs.
    expect(track.duration, const Duration(seconds: 355));
    expect(track.artists.single.name, 'The Ferrous Sea');
    expect(track.artists.single.id?.pluginId, examplePluginId);
    expect(track.album?.title, 'Iron in the Water');
    expect(track.year, 2021);
    // `extra` is provider-private. The host carries it and never reads it.
    expect(track.extra['exampleFixtureId'], 'iron-in-the-water');
    // Metadata only: this plugin claims no playback rights at all.
    expect(track.availability, SwayveAvailability.none);

    expect(result.albums.single.title, 'Iron in the Water');
    expect(result.partial, isFalse);
    expect(result.cursor, isNull);
  });

  test('an unresolvable credit becomes a ref with no id', () async {
    final search = await provider();

    final result = await search.search(
      const SwayveSearchQuery(text: 'the long weld'),
    );

    final artists = result.tracks.single.artists;
    expect(artists.map((ref) => ref.name), ['The Ferrous Sea', 'Wren Adeyemi']);
    // Wren Adeyemi is credited but is not in the catalogue, so there is
    // nowhere to navigate to. A null id says that; a made-up id would send the
    // host to a page that does not exist.
    expect(artists.last.id, isNull);
  });

  test('matching is case-insensitive', () async {
    final search = await provider();

    final lower = await search.search(const SwayveSearchQuery(text: 'iron'));
    final upper = await search.search(const SwayveSearchQuery(text: 'IRoN'));

    expect(upper.tracks, lower.tracks);
    expect(upper.albums, lower.albums);
    expect(lower.tracks, isNotEmpty);
  });

  test('limit is a ceiling per kind, not a total', () async {
    final search = await provider();

    final result = await search.search(
      // "a" appears in every title in the fixture, so an unbounded search
      // would return many of each kind.
      const SwayveSearchQuery(text: 'a', limit: 2),
    );

    expect(result.tracks, hasLength(2));
    expect(result.albums, hasLength(2));
    expect(result.artists, hasLength(2));
  });

  test('kinds the caller did not ask for are not returned', () async {
    final search = await provider();

    final result = await search.search(
      const SwayveSearchQuery(text: 'iron', kinds: {SwayveSearchKind.track}),
    );

    expect(result.tracks, isNotEmpty);
    expect(result.albums, isEmpty);
    expect(result.artists, isEmpty);
    expect(result.playlists, isEmpty);
  });

  test('playlists are always empty, because that capability is not declared',
      () async {
    final search = await provider();

    final result = await search.search(
      const SwayveSearchQuery(text: 'a', kinds: {SwayveSearchKind.playlist}),
    );

    // Empty, not a thrown SwayvePluginUnsupportedException: the provider can
    // answer the question, and the answer is "none".
    expect(result.playlists, isEmpty);
  });

  test('finding nothing is a result, not a failure', () async {
    final search = await provider();

    final noMatch = await search.search(
      const SwayveSearchQuery(text: 'zzzz no such thing'),
    );
    final blank = await search.search(const SwayveSearchQuery(text: '   '));

    // A plugin whose source has nothing to say must still answer. This is the
    // same provider over an empty catalogue, which is what a real plugin looks
    // like on a brand-new account.
    final emptyContext = FakeSwayvePluginContext();
    addTearDown(emptyContext.close);
    await ExamplePlugin(catalogue: ExampleCatalogue.empty)
        .initialize(emptyContext);
    final nothingToSearch = await emptyContext.searchProviders.single.search(
      const SwayveSearchQuery(text: 'iron'),
    );

    for (final result in [noMatch, blank, nothingToSearch]) {
      expect(result.tracks, isEmpty);
      expect(result.albums, isEmpty);
      expect(result.artists, isEmpty);
      expect(result.partial, isFalse);
    }
  });

  test('a cancelled token stops the search', () async {
    final search = await provider();
    final source = SwayveCancellationTokenSource();
    source.cancel();

    await expectLater(
      search.search(
        const SwayveSearchQuery(text: 'a'),
        cancel: source.token,
      ),
      throwsA(
        isA<SwayvePluginCancelledException>()
            .having((error) => error.code, 'code', 'plugin_cancelled'),
      ),
    );
  });

  test('an uncancelled token changes nothing', () async {
    final search = await provider();
    final source = SwayveCancellationTokenSource();

    final result = await search.search(
      const SwayveSearchQuery(text: 'iron'),
      cancel: source.token,
    );

    expect(result.tracks, isNotEmpty);
    expect(source.isCancelled, isFalse);
  });
}
