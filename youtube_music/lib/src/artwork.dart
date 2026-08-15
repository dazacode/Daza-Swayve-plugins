import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'json_path.dart';

/// Turning YouTube Music's images into [SwayveImageRef]s the host is actually
/// allowed to fetch.
///
/// Two rules run through everything here.
///
/// **A plugin must not hand the host a URL its own manifest does not cover.**
/// `SwayveImageRef` is a location the *host* fetches, and it fetches it
/// through the same restricted client the plugin would have used. An image URL
/// on an undeclared host is therefore a broken image at best and a silent
/// attempt to widen the plugin's own network reach at worst. Every reference
/// this file produces is checked against [kYouTubeMusicAllowedHosts] before it
/// is returned, and an unallowed one becomes `null` — an absent fact, which is
/// exactly what the SDK says a null optional means.
///
/// **A size is an intent, not a promise.** [forVideo] can satisfy any size
/// exactly, because YouTube publishes a fixed ladder of thumbnail variants per
/// video id and no request is needed to know their URLs. [fromThumbnails] can
/// only pick the closest of whatever the payload offered, and reports the real
/// dimensions of what it picked.
abstract final class YouTubeMusicArtwork {
  /// The `i.ytimg.com` variant that best serves [size], with its real pixel
  /// dimensions.
  static _Variant _variantFor(SwayveArtworkSize size) => switch (size) {
        SwayveArtworkSize.thumbnail => const _Variant('default', 120, 90),
        SwayveArtworkSize.medium => const _Variant('mqdefault', 320, 180),
        SwayveArtworkSize.large => const _Variant('hqdefault', 480, 360),
        SwayveArtworkSize.original =>
          const _Variant('maxresdefault', 1280, 720),
      };

  /// The approximate width [size] is asking for, used to choose among the
  /// variable-sized images a payload happens to carry.
  static int targetWidth(SwayveArtworkSize size) => switch (size) {
        SwayveArtworkSize.thumbnail => 120,
        SwayveArtworkSize.medium => 320,
        SwayveArtworkSize.large => 544,
        SwayveArtworkSize.original => 1 << 20,
      };

  /// The thumbnail for a video id at [size].
  ///
  /// Derived, not fetched: the variant ladder under `i.ytimg.com/vi/<id>/` is
  /// stable and public, so track artwork costs zero requests and always lands
  /// on a declared host.
  static SwayveImageRef forVideo(
    String videoId, {
    SwayveArtworkSize size = SwayveArtworkSize.medium,
  }) {
    final _Variant variant = _variantFor(size);
    return SwayveImageRef(
      uri: Uri.https('i.ytimg.com', '/vi/$videoId/${variant.name}.jpg'),
      width: variant.width,
      height: variant.height,
    );
  }

  /// The best allowed image from an InnerTube `thumbnails` array, or `null`.
  ///
  /// Returns `null` when the array is empty **or** when every candidate lives
  /// on a host the manifest does not declare. YouTube Music serves most album
  /// and artist art from `lh3.googleusercontent.com`, which this manifest does
  /// not list, so in practice that second case is the common one — see the
  /// README section "Artwork the plugin will not show you".
  static SwayveImageRef? fromThumbnails(
    List<Object?> thumbnails, {
    SwayveArtworkSize size = SwayveArtworkSize.medium,
  }) {
    final int target = targetWidth(size);
    SwayveImageRef? best;
    int bestDistance = -1;
    for (final Object? entry in thumbnails) {
      final String? raw = stringAt(entry, const <Object>['url']);
      if (raw == null) continue;
      final Uri? uri = Uri.tryParse(raw);
      if (uri == null || !uri.hasScheme || !isAllowedHost(uri.host)) continue;
      final int? width = intAt(entry, const <Object>['width']);
      final int distance = ((width ?? 0) - target).abs();
      if (best == null || distance < bestDistance) {
        best = SwayveImageRef(
          uri: uri,
          width: width,
          height: intAt(entry, const <Object>['height']),
        );
        bestDistance = distance;
      }
    }
    return best;
  }

  /// The best allowed image from a renderer's thumbnail block, or `null`.
  ///
  /// InnerTube nests the same array under several wrappers depending on the
  /// renderer; all the known spellings are probed in turn.
  static SwayveImageRef? fromRenderer(
    Object? renderer, {
    SwayveArtworkSize size = SwayveArtworkSize.medium,
  }) {
    const List<List<Object>> paths = <List<Object>>[
      <Object>[
        'thumbnail',
        'musicThumbnailRenderer',
        'thumbnail',
        'thumbnails',
      ],
      <Object>[
        'thumbnailRenderer',
        'musicThumbnailRenderer',
        'thumbnail',
        'thumbnails',
      ],
      <Object>[
        'thumbnail',
        'croppedSquareThumbnailRenderer',
        'thumbnail',
        'thumbnails',
      ],
      <Object>['thumbnail', 'thumbnails'],
      <Object>['thumbnails'],
    ];
    for (final List<Object> path in paths) {
      final List<Object?> thumbnails = listAt(renderer, path);
      if (thumbnails.isEmpty) continue;
      final SwayveImageRef? found = fromThumbnails(thumbnails, size: size);
      if (found != null) return found;
    }
    return null;
  }
}

final class _Variant {
  const _Variant(this.name, this.width, this.height);

  final String name;
  final int width;
  final int height;
}
