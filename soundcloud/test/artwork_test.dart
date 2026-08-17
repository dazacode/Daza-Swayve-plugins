import 'package:soundcloud/soundcloud.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('SoundCloudArtwork.resized', () {
    final Uri original = Uri.parse(
      'https://i1.sndcdn.com/artworks-abc123-0-large.jpg',
    );

    test('maps each SwayveArtworkSize onto its own token', () {
      expect(
        SoundCloudArtwork.resized(original, SwayveArtworkSize.thumbnail).toString(),
        endsWith('-t120x120.jpg'),
      );
      expect(
        SoundCloudArtwork.resized(original, SwayveArtworkSize.medium).toString(),
        endsWith('-t200x200.jpg'),
      );
      expect(
        SoundCloudArtwork.resized(original, SwayveArtworkSize.large).toString(),
        endsWith('-t500x500.jpg'),
      );
      expect(
        SoundCloudArtwork.resized(original, SwayveArtworkSize.original).toString(),
        endsWith('-original.jpg'),
      );
    });

    test('is a no-op on a url it does not recognise', () {
      final Uri weird = Uri.parse('https://i1.sndcdn.com/no-token-here.jpg');
      expect(
        SoundCloudArtwork.resized(weird, SwayveArtworkSize.large),
        weird,
      );
    });
  });

  group('SoundCloudArtwork.build', () {
    test('drops images on undeclared hosts', () {
      final SwayveImageRef? ref = SoundCloudArtwork.build(
        'https://evil.example.com/artworks-abc-0-large.jpg',
        SwayveArtworkSize.medium,
      );
      expect(ref, isNull);
    });

    test('keeps images on declared hosts and reports fixed dimensions', () {
      final SwayveImageRef? ref = SoundCloudArtwork.build(
        'https://i1.sndcdn.com/artworks-abc-0-large.jpg',
        SwayveArtworkSize.medium,
      );
      expect(ref, isNotNull);
      expect(ref!.width, 200);
      expect(ref.height, 200);
    });

    test('null for absent or empty input', () {
      expect(SoundCloudArtwork.build(null, SwayveArtworkSize.medium), isNull);
      expect(SoundCloudArtwork.build('', SwayveArtworkSize.medium), isNull);
    });
  });

  group('SoundCloudArtworkProvider — costs a request, unlike YouTube Music', () {
    late PluginHarness harness;

    setUp(() async {
      harness = await PluginHarness.start(timeouts: fastTimeouts);
    });
    tearDown(() => harness.stop());

    test('a track falls back to the uploader avatar when it has no artwork', () async {
      harness.enqueueClientId();
      harness.http.enqueueJson(<String, Object?>{
        'id': 1,
        'title': 'No Art',
        'user': <String, Object?>{
          'id': 2,
          'kind': 'user',
          'username': 'Someone',
          'avatar_url': 'https://i1.sndcdn.com/avatars-x-0-large.jpg',
        },
      });

      final SwayveImageRef? ref =
          await harness.artwork.artwork(SoundCloudIds.track(1));
      expect(ref, isNotNull);
      expect(ref!.uri.toString(), contains('avatars-x'));
    });

    test('null for a foreign or malformed id, without a request', () async {
      final SwayveImageRef? ref = await harness.artwork.artwork(
        const SwayveMediaId('other.plugin', 'x'),
      );
      expect(ref, isNull);
      expect(harness.http.requests, isEmpty);
    });
  });
}
