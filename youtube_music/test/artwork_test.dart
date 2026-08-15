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

  group('track artwork is derived, not fetched', () {
    test('each size maps onto its own variant', () async {
      const Map<SwayveArtworkSize, String> expected =
          <SwayveArtworkSize, String>{
        SwayveArtworkSize.thumbnail: '/vi/kJQP7kiw5Fk/default.jpg',
        SwayveArtworkSize.medium: '/vi/kJQP7kiw5Fk/mqdefault.jpg',
        SwayveArtworkSize.large: '/vi/kJQP7kiw5Fk/hqdefault.jpg',
        SwayveArtworkSize.original: '/vi/kJQP7kiw5Fk/maxresdefault.jpg',
      };

      for (final MapEntry<SwayveArtworkSize, String> entry
          in expected.entries) {
        final SwayveImageRef? image = await harness.artwork.artwork(
          YouTubeMusicIds.mediaId('kJQP7kiw5Fk'),
          size: entry.key,
        );
        expect(image, isNotNull);
        expect(image!.uri.host, 'i.ytimg.com');
        expect(image.uri.path, entry.value);
        expect(image.width, isNotNull);
        expect(image.height, isNotNull);
      }

      expect(
        harness.http.requests,
        isEmpty,
        reason: 'Artwork is asked for once per visible row; fetching to '
            'answer would turn one scroll into fifty requests.',
      );
    });

    test('sizes are ordered, so a larger intent gets a larger image', () async {
      final SwayveImageRef small = (await harness.artwork.artwork(
        YouTubeMusicIds.mediaId('kJQP7kiw5Fk'),
        size: SwayveArtworkSize.thumbnail,
      ))!;
      final SwayveImageRef large = (await harness.artwork.artwork(
        YouTubeMusicIds.mediaId('kJQP7kiw5Fk'),
        size: SwayveArtworkSize.original,
      ))!;

      expect(large.width! > small.width!, isTrue);
    });

    test('an id from another plugin gets null', () async {
      final SwayveImageRef? image = await harness.artwork.artwork(
        const SwayveMediaId('dev.someone.else.plugin', 'kJQP7kiw5Fk'),
      );
      expect(image, isNull);
      expect(harness.http.requests, isEmpty);
    });
  });

  group('images on undeclared hosts are dropped', () {
    test('an album whose art is on lh3 reports no artwork of its own',
        () async {
      harness.http.enqueueJson(fixture('browse_album.json'));
      final SwayveImageRef? image = await harness.artwork.artwork(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      expect(
        image,
        isNull,
        reason: 'The fixture serves album art from lh3.googleusercontent.com, '
            'which the manifest does not declare. Handing the host a URL it '
            'is not permitted to fetch would widen the plugin\'s own reach.',
      );
    });

    test('an artist image on an undeclared host is dropped too', () async {
      harness.http.enqueueJson(fixture('browse_artist.json'));
      final SwayveArtist? artist = await harness.catalog.artist(
        YouTubeMusicIds.mediaId('UCq3rGZ1Zs9d0dTqRPcJHXyA'),
      );

      expect(artist!.image, isNull);
    });

    test('an image on a declared host is kept', () {
      final SwayveImageRef? image = YouTubeMusicArtwork.fromThumbnails(
        <Object?>[
          <String, Object?>{
            'url': 'https://lh3.googleusercontent.com/x=w120-h120',
            'width': 120,
            'height': 120,
          },
          <String, Object?>{
            'url': 'https://i.ytimg.com/vi/kJQP7kiw5Fk/hqdefault.jpg',
            'width': 480,
            'height': 360,
          },
        ],
        size: SwayveArtworkSize.large,
      );

      expect(image, isNotNull);
      expect(image!.uri.host, 'i.ytimg.com');
      expect(image.width, 480);
    });

    test('search results carry derived track art, never payload art', () async {
      harness.http.enqueueJson(fixture('search_all.json'));
      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(text: 'aster vale'),
      );

      for (final SwayveTrack track in result.tracks) {
        expect(track.artwork, isNotNull);
        expect(track.artwork!.uri.host, 'i.ytimg.com');
      }
      expect(
        result.albums.single.artwork,
        isNull,
        reason: 'The album row only offered an lh3 thumbnail.',
      );
    });
  });
}
