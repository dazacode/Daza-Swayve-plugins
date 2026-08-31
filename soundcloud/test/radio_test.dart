import 'package:soundcloud/soundcloud.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late PluginHarness harness;

  setUp(() async {
    harness = await PluginHarness.start(timeouts: fastTimeouts);
  });
  tearDown(() => harness.stop());

  test('starts a request-free station only for SoundCloud tracks', () async {
    final SwayveRadio? radio = await harness.radio.startRadio(
      SoundCloudIds.track(111222333),
    );

    expect(radio, isNotNull);
    expect(radio!.id, SoundCloudIds.radio(111222333));
    expect(radio.seed, SoundCloudIds.track(111222333));
    expect(radio.extra['seedTrackId'], 111222333);
    expect(harness.http.requests, isEmpty);
    expect(
      await harness.radio.startRadio(SoundCloudIds.playlist(7001)),
      isNull,
    );
  });

  test('parses related tracks, drops the seed, and forwards the cursor',
      () async {
    harness.enqueueClientId();
    harness.http.enqueueText(fixtureText('radio_related.json'));

    final SwayvePage<SwayveTrack> page = await harness.radio.radioTracks(
      const SwayveRadio(
        id: SwayveMediaId('app.swayve.plugins.soundcloud', 'r111222333'),
      ),
      const SwayveBrowseRequest(limit: 2),
    );

    expect(page.items.map((track) => track.title), <String>[
      'Related One',
      'Related Two',
    ]);
    expect(page.items.every((track) => track.canSeedRadio), isTrue);
    expect(page.cursor, startsWith('https://api-v2.soundcloud.com/'));
    expect(harness.requestedUrls.last.path, '/tracks/111222333/related');
    expect(harness.requestedUrls.last.queryParameters['limit'], '2');
  });

  test('related is a finite, deduplicated read-only shelf', () async {
    harness.enqueueClientId();
    harness.http.enqueueText(fixtureText('radio_related.json'));

    final List<SwayveTrack> tracks =
        await harness.radio.related(SoundCloudIds.track(111222333));

    expect(tracks.map((track) => track.title), <String>[
      'Related One',
      'Related Two',
    ]);
    expect(harness.requestedUrls.last.queryParameters['limit'], '50');
    expect(
      await harness.radio.related(SoundCloudIds.user(555666)),
      isEmpty,
    );
  });

  test('foreign station handles answer empty without a request', () async {
    final SwayvePage<SwayveTrack> page = await harness.radio.radioTracks(
      const SwayveRadio(id: SwayveMediaId('other.plugin', 'r111222333')),
      SwayveBrowseRequest.first,
    );
    expect(page.items, isEmpty);
    expect(harness.http.requests, isEmpty);
  });
}
