// Catalog: cursor paging that terminates, sort as a hint, and lookups that
// are allowed to miss.

import 'package:swayve_plugin_example/example.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeSwayvePluginContext context;
  late SwayveCatalogProvider catalog;

  setUp(() async {
    context = FakeSwayvePluginContext();
    await ExamplePlugin().initialize(context);
    catalog = context.catalogProviders.single;
  });

  tearDown(() => context.close());

  test('paging walks the whole catalogue and terminates', () async {
    final seen = <SwayveTrack>[];
    var request = const SwayveBrowseRequest(limit: 3);
    var pages = 0;

    while (true) {
      final page = await catalog.tracks(request);
      seen.addAll(page.items);
      pages++;
      // A pager that does not terminate is the classic cursor bug, and it
      // hangs the host rather than failing it. Bound the loop so this test
      // fails instead of never finishing.
      expect(pages, lessThan(20), reason: 'paging did not terminate');
      if (!page.hasMore) break;
      request = request.next(page.cursor!);
    }

    expect(pages, 3, reason: '8 tracks at 3 per page');
    expect(seen, hasLength(8));
    // Every item exactly once: no gaps, no repeats across the page boundary.
    expect(seen.map((track) => track.id).toSet(), hasLength(8));
  });

  test('the final page carries no cursor', () async {
    // `hasMore` is defined purely by the presence of a cursor, so a provider
    // that always returns one keeps the host asking forever.
    final page = await catalog.albums(const SwayveBrowseRequest(limit: 100));

    expect(page.items, hasLength(3));
    expect(page.cursor, isNull);
    expect(page.hasMore, isFalse);
  });

  test('a page never returns more than the requested limit', () async {
    final page = await catalog.tracks(const SwayveBrowseRequest(limit: 2));

    expect(page.items, hasLength(2));
    expect(page.hasMore, isTrue);
  });

  test('paging past the end is an empty page, not an error', () async {
    final page = await catalog.artists(
      const SwayveBrowseRequest(cursor: '99'),
    );

    expect(page.items, isEmpty);
    expect(page.hasMore, isFalse);
  });

  test('a cursor this plugin could not have minted is malformed', () async {
    // Guessing would silently serve page one to a caller that believed it was
    // reading page four.
    await expectLater(
      catalog.tracks(const SwayveBrowseRequest(cursor: 'not-a-cursor')),
      throwsA(
        isA<SwayvePluginMalformedResponseException>().having(
          (error) => error.code,
          'code',
          'plugin_malformed_response',
        ),
      ),
    );
  });

  test('alphabetical sort is honoured', () async {
    final page = await catalog.artists(
      const SwayveBrowseRequest(sort: SwayveSortOrder.alphabetical),
    );

    expect(
      page.items.map((artist) => artist.name),
      ['Halcyon Bureau', 'Nadia Okonkwo', 'The Ferrous Sea'],
    );
  });

  test('a sort this provider cannot do falls back to natural order', () async {
    // Sort is a hint. Failing a browse because the caller preferred "popular"
    // would be a worse outcome for the user than a list in fixture order.
    final page = await catalog.artists(
      const SwayveBrowseRequest(sort: SwayveSortOrder.popular),
    );

    expect(page.items.first.name, 'Nadia Okonkwo');
  });

  test('album and artist lookups resolve ids this plugin minted', () async {
    final listed = await catalog.albums(const SwayveBrowseRequest());
    final expected = listed.items.first;

    final fetched = await catalog.album(expected.id);

    expect(fetched, expected);

    final artist = await catalog.artist(_id('artist:nadia-okonkwo'));
    expect(artist?.name, 'Nadia Okonkwo');
  });

  test('a lookup that misses returns null rather than throwing', () async {
    // An id we minted for something no longer in the catalogue. The host's
    // library is full of ids it saved months ago.
    expect(await catalog.album(_id('album:deleted-last-year')), isNull);
    expect(await catalog.artist(_id('artist:never-existed')), isNull);
  });

  test('an id another plugin minted is not ours to answer for', () async {
    const foreign = SwayveMediaId(
      'app.swayve.plugins.youtube_music',
      'album:low-tide-hours',
    );

    // Note the value would have matched, had we trusted it.
    expect(await catalog.album(foreign), isNull);
  });

  test('a cancelled token stops a browse', () async {
    final source = SwayveCancellationTokenSource()..cancel();

    await expectLater(
      catalog.tracks(const SwayveBrowseRequest(), cancel: source.token),
      throwsA(isA<SwayvePluginCancelledException>()),
    );
  });
}

SwayveMediaId _id(String value) => SwayveMediaId(examplePluginId, value);
