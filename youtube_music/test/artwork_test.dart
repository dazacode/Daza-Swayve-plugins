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
        // `hqdefault` rather than `maxresdefault`: the larger variants are only
        // generated for videos uploaded above that resolution, so asking for
        // one is a 404 for a great deal of the catalogue — and a 404 draws the
        // placeholder rather than a smaller picture.
        SwayveArtworkSize.original: '/vi/kJQP7kiw5Fk/hqdefault.jpg',
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

  group('the cover art the service actually draws', () {
    test('an album serves its real sleeve', () async {
      harness.http.enqueueJson(fixture('browse_album.json'));
      final SwayveImageRef? image = await harness.artwork.artwork(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );

      expect(
        image,
        isNotNull,
        reason: 'The sleeve is on lh3.googleusercontent.com, which the '
            'manifest now declares. Dropping it left every record in the app '
            'drawing a placeholder.',
      );
      expect(image!.uri.host, 'lh3.googleusercontent.com');
    });

    test('an artist image is kept too', () async {
      harness.http.enqueueJson(fixture('browse_artist.json'));
      final SwayveArtist? artist = await harness.catalog.artist(
        YouTubeMusicIds.mediaId('UCq3rGZ1Zs9d0dTqRPcJHXyA'),
      );

      expect(artist!.image, isNotNull);
    });

    test('a sleeve is asked for at the size it will be drawn', () async {
      harness.http.enqueueJson(fixture('browse_album.json'));
      final SwayveImageRef image = (await harness.artwork.artwork(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
        size: SwayveArtworkSize.large,
      ))!;

      expect(
        image.uri.pathSegments.last,
        contains('=w544-h544'),
        reason: 'The payload offers a small thumbnail because it was '
            'describing a list. The same picture at 544 is one string away '
            'and costs no request.',
      );
      expect(image.width, 544);
      expect(image.height, 544);
    });

    test('a size suffix already present is replaced, not appended', () {
      final SwayveImageRef image = YouTubeMusicArtwork.resized(
        SwayveImageRef(
          uri: Uri.parse(
            'https://lh3.googleusercontent.com/AAxyz=w60-h60-l90-rj',
          ),
          width: 60,
          height: 60,
        ),
        544,
      );

      expect(
        image.uri.toString(),
        'https://lh3.googleusercontent.com/AAxyz=w544-h544-l90-rj',
      );
    });

    test('a host that does not size its URLs is left alone', () {
      final Uri original =
          Uri.parse('https://i.ytimg.com/vi/kJQP7kiw5Fk/hqdefault.jpg');
      final SwayveImageRef image = YouTubeMusicArtwork.resized(
        SwayveImageRef(uri: original, width: 480, height: 360),
        544,
      );

      expect(
        image.uri,
        original,
        reason: 'Rewriting the size suffix of a host that does not use one '
            'turns a working image into a 404.',
      );
    });

    test('the sleeve beats the video frame, whatever their stated sizes', () {
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
      expect(
        image!.uri.host,
        'lh3.googleusercontent.com',
        reason: 'Choosing by stated width alone is how a 480-pixel video frame '
            'beat a 120-pixel sleeve, and it is what made covers look '
            'low-resolution and stretched: the frame is 16:9 and is only ever '
            'the sizes YouTube publishes, while the sleeve is square and can '
            'be asked for at any size for free.',
      );
      expect(
        image.width,
        544,
        reason: 'Asked for at the size it will be drawn at rather than '
            'accepted at the size the payload happened to mention.',
      );
    });

    test('a video frame is still used when there is no sleeve', () {
      final SwayveImageRef? image = YouTubeMusicArtwork.fromThumbnails(
        <Object?>[
          <String, Object?>{
            'url': 'https://i.ytimg.com/vi/kJQP7kiw5Fk/hqdefault.jpg',
            'width': 480,
            'height': 360,
          },
        ],
        size: SwayveArtworkSize.large,
      );

      expect(image, isNotNull);
      expect(
        image!.uri.host,
        'i.ytimg.com',
        reason:
            'A track that is genuinely a video rather than a release has no '
            'square art at all, and a frame from it beats a placeholder.',
      );
    });

    test('search results carry the square art, not a video frame', () async {
      harness.http.enqueueJson(fixture('search_all.json'));
      final SwayveSearchResult result = await harness.search.search(
        const SwayveSearchQuery(text: 'aster vale'),
      );

      for (final SwayveTrack track in result.tracks) {
        expect(track.artwork, isNotNull);
      }
      expect(
        result.albums.single.artwork,
        isNotNull,
        reason: 'The album row offers an lh3 thumbnail, and that is the sleeve '
            'the service itself draws.',
      );
    });

    test('a track with no square art still falls back to its frame', () {
      // A video rather than a release: nothing in the renderer carries a
      // sleeve, so the derived `i.ytimg.com` frame is the honest answer and is
      // still better than initials in a box.
      final SwayveImageRef image = YouTubeMusicArtwork.forVideo(
        'kJQP7kiw5Fk',
        size: SwayveArtworkSize.large,
      );

      expect(image.uri.host, 'i.ytimg.com');
      expect(image.uri.path, contains('hqdefault'));
    });
  });
}
