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

  test('progressive is preferred over hls when both exist', () async {
    harness.enqueueClientId();
    harness.http
      ..enqueueText(fixtureText('track_full.json'))
      ..enqueueText(fixtureText('media_resolution.json'));

    final SwayvePlayableSource source =
        await harness.stream.resolvePlayback(SoundCloudIds.track(111222333));

    expect(source.kind, SwayvePlayableKind.directUrl);
    expect(source.uri.toString(), contains('cf-media.sndcdn.com'));
    expect(source.availability.streamable, isTrue);
    expect(
      source.availability.downloadable,
      isTrue,
      reason: 'track_full.json reports downloadable: true',
    );

    // The transcoding request itself carried the current client_id.
    final Uri resolveRequest = harness.requestedUrls[3];
    expect(resolveRequest.path, contains('/stream/progressive'));
    expect(resolveRequest.queryParameters['client_id'], 'fake-client-id-123');
  });

  test('falls back to hls when no progressive rendition exists', () async {
    harness.enqueueClientId();
    harness.http
      ..enqueueText(fixtureText('track_hls_only.json'))
      ..enqueueText(fixtureText('media_resolution.json'));

    final SwayvePlayableSource source =
        await harness.stream.resolvePlayback(SoundCloudIds.track(222333444));

    expect(source.kind, SwayvePlayableKind.hlsUrl);
    expect(source.availability.downloadable, isFalse);
  });

  test('downloadable on the resolved source matches the track flag both ways', () async {
    harness.enqueueClientId();
    harness.http
      ..enqueueText(fixtureText('track_full.json'))
      ..enqueueText(fixtureText('media_resolution.json'));
    final SwayvePlayableSource downloadable =
        await harness.stream.resolvePlayback(SoundCloudIds.track(111222333));
    expect(downloadable.availability.downloadable, isTrue);

    harness.http
      ..enqueueText(fixtureText('track_hls_only.json'))
      ..enqueueText(fixtureText('media_resolution.json'));
    final SwayvePlayableSource notDownloadable =
        await harness.stream.resolvePlayback(SoundCloudIds.track(222333444));
    expect(notDownloadable.availability.downloadable, isFalse);
  });

  test('a track with no usable transcoding throws Unsupported, not Unavailable', () async {
    harness.enqueueClientId();
    harness.http.enqueueText(fixtureText('track_no_transcodings.json'));

    await expectLater(
      harness.stream.resolvePlayback(SoundCloudIds.track(333444555)),
      throwsA(isA<SwayvePluginUnsupportedException>()),
    );
  });

  test('a non-track id throws Unsupported without a request', () async {
    await expectLater(
      harness.stream.resolvePlayback(SoundCloudIds.playlist(1)),
      throwsA(isA<SwayvePluginUnsupportedException>()),
    );
    expect(harness.http.requests, isEmpty);
  });

  test('a track that no longer resolves throws Unsupported', () async {
    harness.enqueueClientId();
    harness.http.enqueueResponse(const SwayveHttpResponse(statusCode: 404));

    await expectLater(
      harness.stream.resolvePlayback(SoundCloudIds.track(1)),
      throwsA(isA<SwayvePluginUnsupportedException>()),
    );
  });

  test('expiresIn carries the documented conservative floor minus the safety margin', () async {
    harness.enqueueClientId();
    harness.http
      ..enqueueText(fixtureText('track_full.json'))
      ..enqueueText(fixtureText('media_resolution.json'));

    final SwayvePlayableSource source =
        await harness.stream.resolvePlayback(SoundCloudIds.track(111222333));

    expect(source.expiresIn, kStreamLifetime - kStreamExpiryMargin);
  });
}
