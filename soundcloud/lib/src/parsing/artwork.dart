/// Sizing SoundCloud's image URLs without a request.
///
/// SoundCloud publishes a fixed variant ladder on the *last path segment* of
/// an `artwork_url`/`avatar_url`, e.g.
/// `https://i1.sndcdn.com/artworks-abCD-0-large.jpg`. Rewriting that segment
/// gets a different rendition of the same image for free — the same trick
/// `YouTubeMusicArtwork.resized` plays on YouTube's own thumbnail ladder.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';

/// Reads and rewrites SoundCloud image URLs.
abstract final class SoundCloudArtwork {
  /// The token SoundCloud's API hands back by default. Matched so it can be
  /// replaced with a more specific rendition.
  static const String _defaultToken = 'large';

  /// Every rendition token this plugin knows how to ask for, smallest first.
  static const List<String> _knownTokens = <String>[
    't50x50',
    't67x67',
    't120x120',
    't200x200',
    't300x300',
    't500x500',
    'original',
  ];

  /// The token used for each [SwayveArtworkSize].
  ///
  /// `thumbnail` maps to `t120x120` rather than the smallest `t50x50`: list
  /// rows on a typical density render meaningfully larger than 50 logical
  /// pixels, and asking for the too-small rung would visibly upscale it.
  static String _tokenFor(SwayveArtworkSize size) => switch (size) {
        SwayveArtworkSize.thumbnail => 't120x120',
        SwayveArtworkSize.medium => 't200x200',
        SwayveArtworkSize.large => 't500x500',
        SwayveArtworkSize.original => 'original',
      };

  /// The pixel dimensions a [_tokenFor] result reports, when it's a fixed
  /// square rendition, or `null` for `original` (source-asset size, unknown
  /// without fetching it).
  static int? _dimensionFor(String token) {
    final RegExpMatch? match = RegExp(r'^t(\d+)x\d+$').firstMatch(token);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// Rewrites [url] to request [size], or returns it unchanged when it does
  /// not look like a SoundCloud image URL this plugin recognises.
  ///
  /// Costs zero requests: the substitution is a plain string replacement on
  /// the last path segment.
  static Uri resized(Uri url, SwayveArtworkSize size) {
    final List<String> segments = url.pathSegments.toList();
    if (segments.isEmpty) return url;
    final String last = segments.last;
    final int dot = last.lastIndexOf('.');
    if (dot <= 0) return url;
    final String stem = last.substring(0, dot);
    final String extension = last.substring(dot);

    final String replacement = _tokenFor(size);
    String? rewrittenStem;
    for (final String token in _knownTokens) {
      if (stem.endsWith('-$token')) {
        rewrittenStem =
            '${stem.substring(0, stem.length - token.length)}$replacement';
        break;
      }
    }
    // Also match the plain default spelling the API hands back before any
    // rewriting has happened.
    rewrittenStem ??= stem.endsWith('-$_defaultToken')
        ? '${stem.substring(0, stem.length - _defaultToken.length)}$replacement'
        : null;
    if (rewrittenStem == null) return url;

    segments[segments.length - 1] = '$rewrittenStem$extension';
    return url.replace(pathSegments: segments);
  }

  /// Builds a [SwayveImageRef] for [rawUrl] at [size], or `null` when
  /// [rawUrl] is absent, unparseable, or on a host the manifest does not
  /// declare.
  ///
  /// Filtering by [isAllowedHost] here — not just at the point of any
  /// eventual fetch — matters because the host is the one that ends up
  /// fetching this URL, through the same restricted client this plugin would
  /// use. An image URL on an undeclared host is at best a broken image and at
  /// worst a quiet attempt to widen this plugin's own network reach.
  static SwayveImageRef? build(String? rawUrl, SwayveArtworkSize size) {
    if (rawUrl == null || rawUrl.isEmpty) return null;
    final Uri? parsed = Uri.tryParse(rawUrl);
    if (parsed == null || !isAllowedHost(parsed.host)) return null;
    final Uri resizedUrl = resized(parsed, size);
    final String token = _tokenFor(size);
    final int? dimension = _dimensionFor(token);
    return SwayveImageRef(
      uri: resizedUrl,
      width: dimension,
      height: dimension,
    );
  }
}
