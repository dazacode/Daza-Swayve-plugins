import 'package:soundcloud/soundcloud.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('isAllowedHost rejects a near-miss host', () {
    expect(isAllowedHost('soundcloud.com.evil.example.com'), isFalse);
    expect(isAllowedHost('evil.example.com'), isFalse);
    expect(isAllowedHost('api-v2.soundcloud.com'), isTrue);
    expect(isAllowedHost('a-v2.sndcdn.com'), isTrue);
    expect(isAllowedHost('i1.sndcdn.com'), isTrue);
  });

  group('every outbound request targets a manifest-declared host', () {
    late PluginHarness harness;

    setUp(() async {
      harness = await PluginHarness.start(timeouts: fastTimeouts);
    });
    tearDown(() => harness.stop());

    void expectAllowlisted() {
      for (final Uri url in harness.requestedUrls) {
        expect(
          manifestAllowsHost(url.host),
          isTrue,
          reason: '$url was not on a host plugin.json declares',
        );
      }
    }

    test('across search', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('search_tracks.json'));
      await harness.search.search(
        const SwayveSearchQuery(text: 'x', kinds: {SwayveSearchKind.track}),
      );
      expectAllowlisted();
    });

    test('across catalog, including a hydrated album lookup', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('charts_top.json'));
      await harness.catalog.tracks(SwayveBrowseRequest.first);

      harness.http.enqueueText(fixtureText('playlist_full.json'));
      await harness.catalog.album(SoundCloudIds.playlist(7001));
      expectAllowlisted();
    });

    test('across playback resolution', () async {
      harness.enqueueClientId();
      harness.http
        ..enqueueText(fixtureText('track_full.json'))
        ..enqueueText(fixtureText('media_resolution.json'));
      await harness.stream.resolvePlayback(SoundCloudIds.track(111222333));
      expectAllowlisted();
    });

    test('across artwork', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('track_full.json'));
      await harness.artwork.artwork(SoundCloudIds.track(111222333));
      expectAllowlisted();
    });

    test('following a next_href cursor', () async {
      harness.enqueueClientId();
      harness.http.enqueueText(fixtureText('search_tracks.json'));
      final SwayveSearchResult first = await harness.search.search(
        const SwayveSearchQuery(text: 'x', kinds: {SwayveSearchKind.track}),
      );

      harness.http.enqueueJson(<String, Object?>{'collection': [], 'next_href': null});
      await harness.search.search(
        SwayveSearchQuery(
          text: 'x',
          kinds: const {SwayveSearchKind.track},
          cursor: first.cursor,
        ),
      );
      expectAllowlisted();
    });

    test('a cursor pointing off-allowlist is rejected as malformed, never followed', () async {
      await expectLater(
        harness.search.search(
          const SwayveSearchQuery(
            text: 'x',
            kinds: {SwayveSearchKind.track},
            cursor: 'sc2|https://evil.example.com/search/tracks|||',
          ),
        ),
        throwsA(isA<SwayvePluginMalformedResponseException>()),
      );
    });
  });
}
