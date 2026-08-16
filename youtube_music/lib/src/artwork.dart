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
  /// The `i.ytimg.com` variant serving [size].
  ///
  /// `original` stops at `hqdefault` rather than reaching for
  /// `maxresdefault`. The larger variants are only generated for videos
  /// uploaded above that resolution, so `maxresdefault` is a 404 for a great
  /// deal of the catalogue — and a 404 here is not a smaller image, it is no
  /// image: the host fetches the URL it was given, gets nothing, and draws the
  /// placeholder with the initials on it. `hqdefault` exists for every video
  /// YouTube has ever served.
  static _Variant _variantFor(SwayveArtworkSize size) => switch (size) {
        SwayveArtworkSize.thumbnail => const _Variant('default', 120, 90),
        SwayveArtworkSize.medium => const _Variant('mqdefault', 320, 180),
        SwayveArtworkSize.large || SwayveArtworkSize.original =>
          const _Variant('hqdefault', 480, 360),
      };

  /// The approximate width [size] is asking for.
  ///
  /// Used both to choose among the variable-sized images a payload happens to
  /// carry and, for the hosts that allow it, to ask for that width directly.
  /// The second use is why `original` is a real number: it used to be a
  /// sentinel meaning "the biggest one mentioned", which picked correctly and
  /// then handed back whatever small rendition a list response had named. 1200
  /// is above the largest sleeve YouTube Music itself requests and is served.
  static int targetWidth(SwayveArtworkSize size) => switch (size) {
        SwayveArtworkSize.thumbnail => 120,
        SwayveArtworkSize.medium => 320,
        SwayveArtworkSize.large => 544,
        SwayveArtworkSize.original => 1200,
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

  /// Google's image hosts, whose URLs state the size they will serve.
  ///
  /// Kept separate from the manifest allowlist because it answers a different
  /// question. That list is about what the plugin may *reach*; this is about
  /// which URLs can be *rewritten*, and rewriting the size suffix of a host
  /// that does not use one would produce a 404 out of a working image.
  static const Set<String> _resizableHosts = <String>{
    'lh3.googleusercontent.com',
  };

  /// [image] rewritten to serve a square of [width] pixels, where it can be.
  ///
  /// Google's image URLs carry their rendition in a suffix on the last path
  /// segment — `…/AAxyz=w60-h60-l90-rj` — and changing it changes what is
  /// served. It costs no request to ask for a bigger one, which is the whole
  /// point: the payload offers a 60-pixel thumbnail because it was drawn in a
  /// list, and the same picture at 544 is one string away.
  ///
  /// The options are the ones YouTube Music's own web player asks for:
  ///
  /// * `w`/`h` — the box to fit, in pixels.
  /// * `l90` — JPEG quality 90. The default is lower and visibly soft once the
  ///   image is being drawn large.
  /// * `rj` — return JPEG, rather than letting the server pick a format the
  ///   host's image decoder may not read.
  ///
  /// Anything on another host is returned unchanged rather than guessed at.
  static SwayveImageRef resized(SwayveImageRef image, int width) {
    final Uri uri = image.uri;
    if (!_resizableHosts.contains(uri.host.toLowerCase())) return image;
    if (uri.pathSegments.isEmpty) return image;

    final String last = uri.pathSegments.last;
    final int marker = last.indexOf('=');
    final String base = marker == -1 ? last : last.substring(0, marker);
    if (base.isEmpty) return image;

    return SwayveImageRef(
      uri: uri.replace(
        pathSegments: <String>[
          ...uri.pathSegments.take(uri.pathSegments.length - 1),
          '$base=w$width-h$width-l90-rj',
        ],
      ),
      width: width,
      height: width,
    );
  }

  /// The best allowed image from an InnerTube `thumbnails` array, or `null`.
  ///
  /// Returns `null` when the array is empty **or** when every candidate lives
  /// on a host the manifest does not declare. The sleeve host is declared, so
  /// that second case is now rare rather than the norm it used to be; artist
  /// portraits served from `yt3.ggpht.com` are the remaining example, and they
  /// stay dropped because widening the allowlist for a decorative image is not
  /// a trade worth asking the user to agree to.
  static SwayveImageRef? fromThumbnails(
    List<Object?> thumbnails, {
    SwayveArtworkSize size = SwayveArtworkSize.medium,
  }) {
    final int target = targetWidth(size);
    // Two candidates rather than one, because the payload frequently carries
    // both kinds and they are not interchangeable.
    //
    // A renderer's `thumbnails` array can hold the record's square sleeve (on
    // `lh3.googleusercontent.com`) and a frame from the video (on
    // `i.ytimg.com`), and picking whichever one's stated width happened to land
    // closest to the target is how a sleeve loses to a frame. That is the
    // low-resolution, letterboxed, stretched-looking cover: it is not a
    // compressed sleeve, it is a screenshot of a video being drawn as one.
    //
    // Width is the wrong tiebreak between the two anyway. A sleeve URL can be
    // rewritten to any size for free — see [resized] — so a 60-pixel sleeve is
    // a 544-pixel sleeve one string away, while a frame is only ever the sizes
    // YouTube publishes. The sleeve therefore wins on principle and the frame
    // is kept only as the answer for a track that has no record behind it.
    SwayveImageRef? sleeve;
    int sleeveDistance = -1;
    SwayveImageRef? frame;
    int frameDistance = -1;

    for (final Object? entry in thumbnails) {
      final String? raw = stringAt(entry, const <Object>['url']);
      if (raw == null) continue;
      final Uri? uri = Uri.tryParse(raw);
      if (uri == null || !uri.hasScheme || !isAllowedHost(uri.host)) continue;
      final int? width = intAt(entry, const <Object>['width']);
      final int distance = ((width ?? 0) - target).abs();
      final SwayveImageRef candidate = SwayveImageRef(
        uri: uri,
        width: width,
        height: intAt(entry, const <Object>['height']),
      );

      if (_resizableHosts.contains(uri.host.toLowerCase())) {
        if (sleeve == null || distance < sleeveDistance) {
          sleeve = candidate;
          sleeveDistance = distance;
        }
      } else if (frame == null || distance < frameDistance) {
        frame = candidate;
        frameDistance = distance;
      }
    }

    // Asked for at the size it is going to be drawn at, rather than accepted
    // at the size the payload happened to mention. A list sends 60-pixel
    // thumbnails because it was describing a list; the same picture at 544 is
    // one string away and costs no request. See [resized].
    //
    // `original` is included rather than excepted. It used to be handed back
    // untouched on the reasoning that the source asset is whatever the payload
    // named — but the payload names a rendition, not an asset, so "original"
    // was returning the largest *thumbnail* mentioned in a list response and
    // the now-playing screen was upscaling a 226-pixel image to fill a phone.
    if (sleeve != null) return resized(sleeve, target);
    return frame;
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
