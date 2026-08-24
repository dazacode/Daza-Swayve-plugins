import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `metadata_search`: finding a candidate for a track this app has not
/// identified, and resolving a pasted URL — the capability that fixes what
/// a structured database like MusicBrainz cannot: an extended mix, a
/// bootleg, an unreleased track, all of which very often live only in
/// YouTube's upload catalogue.
void main() {
  late PluginHarness harness;

  setUp(() async {
    harness = await PluginHarness.start();
  });

  tearDown(() => harness.stop());

  group('searchTrack', () {
    test('asks both shelves and returns candidates from each', () async {
      harness.http
        ..enqueueJson(fixture('search_all.json'))
        ..enqueueJson(fixture('search_videos.json'));

      final List<SwayveMetadataCandidate> candidates =
          await harness.metadataSearch.searchTrack(
        const SwayveMetadataQuery(
          title: 'Nightdrive',
          artists: <String>['Aster Vale'],
        ),
      );

      expect(harness.http.requests, hasLength(2));
      expect(
        harness.bodyAt(0)['query'],
        'Nightdrive Aster Vale',
        reason: 'The title and primary artist, joined the way a person '
            'would type them into the search box.',
      );
      expect(candidates, isNotEmpty);
      expect(
        candidates.any((c) => c.title == 'Nightdrive (unreleased demo)'),
        isTrue,
        reason: 'The video shelf is what carries a song that never made it '
            'onto the licensed catalogue.',
      );
    });

    test('a recording in both shelves is returned once', () async {
      harness.http
        ..enqueueJson(fixture('search_all.json'))
        ..enqueueJson(fixture('search_videos.json'));

      final List<SwayveMetadataCandidate> candidates =
          await harness.metadataSearch.searchTrack(
        const SwayveMetadataQuery(title: 'Nightdrive'),
      );

      expect(
        candidates.where((c) => c.providerItemId == 'kJQP7kiw5Fk'),
        hasLength(1),
      );
    });

    test('carries the fields a resolver needs to score a match', () async {
      harness.http
        ..enqueueJson(fixture('search_all.json'))
        ..enqueueJson(fixture('search_videos.json'));

      final List<SwayveMetadataCandidate> candidates =
          await harness.metadataSearch.searchTrack(
        const SwayveMetadataQuery(title: 'Nightdrive'),
      );

      final SwayveMetadataCandidate found =
          candidates.firstWhere((c) => c.providerItemId == 'kJQP7kiw5Fk');
      expect(found.title, 'Nightdrive');
      expect(found.artists, contains('Aster Vale'));
      expect(found.album, 'Long Way Home');
      expect(found.duration, const Duration(minutes: 3, seconds: 41));
      expect(
        found.sourceUrl.toString(),
        'https://music.youtube.com/watch?v=kJQP7kiw5Fk',
      );
    });

    test('an empty query makes no request at all', () async {
      final List<SwayveMetadataCandidate> candidates =
          await harness.metadataSearch.searchTrack(
        const SwayveMetadataQuery(),
      );

      expect(candidates, isEmpty);
      expect(harness.http.requests, isEmpty);
    });
  });

  group('resolveUrl', () {
    Future<SwayveMetadataCandidate?> resolve(Uri url) {
      harness.http
        ..enqueueJson(fixture('player_visitor_id.json'))
        ..enqueueJson(fixture('player_ok.json'));
      return harness.metadataSearch.resolveUrl(url);
    }

    test('a music.youtube.com watch URL resolves', () async {
      final SwayveMetadataCandidate? candidate = await resolve(
        Uri.parse('https://music.youtube.com/watch?v=dQw4w9WgXcQ'),
      );

      expect(candidate, isNotNull);
      expect(candidate!.providerItemId, 'dQw4w9WgXcQ');
      expect(candidate.title, 'Nightdrive');
      expect(candidate.duration, const Duration(minutes: 3, seconds: 7));
    });

    test('a youtu.be short link resolves the same way', () async {
      final SwayveMetadataCandidate? candidate = await resolve(
        Uri.parse('https://youtu.be/dQw4w9WgXcQ'),
      );

      expect(candidate, isNotNull);
      expect(candidate!.providerItemId, 'dQw4w9WgXcQ');
    });

    test('a plain youtube.com watch URL resolves too', () async {
      final SwayveMetadataCandidate? candidate = await resolve(
        Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
      );

      expect(candidate, isNotNull);
    });

    test('a URL with no recognisable video id resolves to nothing, no request',
        () async {
      final SwayveMetadataCandidate? candidate =
          await harness.metadataSearch.resolveUrl(
        Uri.parse('https://music.youtube.com/playlist?list=PLabc'),
      );

      expect(candidate, isNull);
      expect(harness.http.requests, isEmpty);
    });

    test('a URL from another service resolves to nothing, no request',
        () async {
      final SwayveMetadataCandidate? candidate =
          await harness.metadataSearch.resolveUrl(
        Uri.parse('https://soundcloud.com/someone/a-track'),
      );

      expect(candidate, isNull);
      expect(harness.http.requests, isEmpty);
    });

    test('an unplayable video resolves to nothing rather than throwing',
        () async {
      harness.http
        ..enqueueJson(fixture('player_visitor_id.json'))
        ..enqueueJson(fixture('player_unavailable.json'));

      final SwayveMetadataCandidate? candidate =
          await harness.metadataSearch.resolveUrl(
        Uri.parse('https://music.youtube.com/watch?v=dQw4w9WgXcQ'),
      );

      expect(candidate, isNull);
    });
  });
}
