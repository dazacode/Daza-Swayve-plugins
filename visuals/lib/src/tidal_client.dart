import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'errors.dart';

/// A small official TIDAL Developer Platform client over `context.http`.
///
/// It intentionally knows nothing about a host widget or a TIDAL page. The
/// only media URL it returns is the HTTPS `link.href` from the official video
/// manifest endpoint.
final class TidalClient {
  /// Creates a client over the host-mediated HTTP transport.
  TidalClient({
    required SwayveHttpClient http,
    required this.region,
    this.timeouts = VisualsTimeouts.manifest,
  }) : _http = http;

  final SwayveHttpClient _http;

  /// The host region used for catalog availability, or `US` when unknown.
  final String region;

  /// The request and operation budgets.
  final VisualsTimeouts timeouts;

  /// Finds and resolves the best TIDAL music video for [track].
  Future<SwayveVisual?> visual(
    SwayveTrack track, {
    required String accessToken,
    SwayveCancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();

    final String? isrc = _isrcFrom(track);
    if (isrc != null) {
      final Map<String, Object?>? byIsrc = await _get(
        _endpoint(
          '/videos',
          <String, String>{
            'filter[isrc]': isrc,
            'countryCode': region,
          },
        ),
        accessToken: accessToken,
        cancel: cancel,
      );
      cancel?.throwIfCancelled();
      final TidalVideo? direct = _bestVideo(
        _videosFrom(byIsrc),
        track,
      );
      if (direct != null) {
        return _manifest(
          direct,
          track,
          accessToken: accessToken,
          cancel: cancel,
        );
      }
    }

    final String query = '${track.artistsLabel} ${track.title}'.trim();
    if (query.isEmpty) return null;
    final Map<String, Object?>? search = await _get(
      _endpoint(
        '/searchResults',
        <String, String>{
          'filter[query]': query.length > 256 ? query.substring(0, 256) : query,
          'include': 'videos',
          'countryCode': region,
        },
      ),
      accessToken: accessToken,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    List<TidalVideo> candidates = _includedVideosFrom(search);
    if (candidates.isEmpty) {
      final List<String> ids = _videoIdsFromSearch(search);
      if (ids.isNotEmpty) {
        final Map<String, Object?>? details = await _get(
          _endpoint(
            '/videos',
            <String, String>{
              'filter[id]': ids.join(','),
              'countryCode': region,
            },
          ),
          accessToken: accessToken,
          cancel: cancel,
        );
        cancel?.throwIfCancelled();
        candidates = _videosFrom(details);
      }
    }

    final TidalVideo? best = _bestVideo(candidates, track);
    if (best == null) return null;
    return _manifest(best, track, accessToken: accessToken, cancel: cancel);
  }

  Future<SwayveVisual?> _manifest(
    TidalVideo video,
    SwayveTrack track, {
    required String accessToken,
    SwayveCancellationToken? cancel,
  }) async {
    final Map<String, Object?>? root = await _get(
      _endpoint(
        '/videoManifests/${Uri.encodeComponent(video.id)}',
        <String, String>{
          'uriScheme': 'HTTPS',
          'usage': 'PLAYBACK',
        },
      ),
      accessToken: accessToken,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();
    if (root == null) return null;

    final Map<String, Object?> data = _object(root['data'], 'data');
    final Map<String, Object?> attributes =
        _object(data['attributes'], 'data.attributes');

    // The SDK has no DRM fields. Handing a DRM manifest to a host that cannot
    // satisfy it would look like a broken visual, so decline it cleanly.
    if (attributes['drmData'] != null) return null;

    final Map<String, Object?> link =
        _object(attributes['link'], 'data.attributes.link');
    final String href = _string(link['href'], 'data.attributes.link.href');
    final Uri? uri = Uri.tryParse(href);
    if (uri == null || uri.scheme != 'https' || !isAllowedHost(uri.host)) {
      throw SwayvePluginMalformedResponseException(
        'TIDAL returned a visual URL outside the declared HTTPS allowlist.',
      );
    }

    return SwayveVisual(
      uri: uri,
      kind: SwayveVisualKind.video,
      source: 'TIDAL',
      loops: true,
      duration: video.duration ?? track.duration,
    );
  }

  Future<Map<String, Object?>?> _get(
    Uri endpoint, {
    required String accessToken,
    SwayveCancellationToken? cancel,
  }) async {
    if (!isAllowedHost(endpoint.host)) {
      throw SwayvePluginUnsupportedException(
        'The visuals plugin will not contact ${endpoint.host}: it is not in '
        'the manifest allowlist.',
      );
    }
    final SwayveHttpResponse response = await _http.get(
      endpoint,
      headers: <String, String>{
        'accept': 'application/vnd.api+json',
        'authorization': 'Bearer $accessToken',
        'user-agent': kUserAgent,
      },
      timeout: timeouts.request,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();
    if (response.statusCode == 404) return null;
    if (!response.isSuccess) {
      throw exceptionForStatus(
        response.statusCode,
        headers: response.headers,
      );
    }
    final Object? decoded = response.bodyAsJson;
    if (decoded is! Map<String, Object?>) {
      throw SwayvePluginMalformedResponseException(
        'TIDAL returned a JSON document instead of an object.',
      );
    }
    return decoded;
  }

  Uri _endpoint(String path, Map<String, String> query) =>
      kTidalApiOrigin.replace(
        path: '/v2$path',
        queryParameters: query,
      );
}

/// A video resource reduced to the fields needed for matching and playback.
final class TidalVideo {
  /// Creates a video candidate.
  const TidalVideo({required this.id, required this.title, this.duration});

  /// Opaque TIDAL video id.
  final String id;

  /// TIDAL's canonical video title.
  final String title;

  /// Video duration, when the API returned a parseable ISO-8601 value.
  final Duration? duration;
}

List<TidalVideo> _includedVideosFrom(Map<String, Object?>? root) {
  if (root == null) return const [];
  final Object? included = root['included'];
  if (included is! List<Object?>) return const [];
  return [
    for (final Object? item in included)
      if (item is Map<String, Object?>) ..._tryVideo(item),
  ];
}

List<TidalVideo> _videosFrom(Map<String, Object?>? root) {
  if (root == null) return const [];
  final Object? data = root['data'];
  if (data is! List<Object?>) return const [];
  return [
    for (final Object? item in data)
      if (item is Map<String, Object?>) ..._tryVideo(item),
  ];
}

List<String> _videoIdsFromSearch(Map<String, Object?>? root) {
  if (root == null || root['data'] is! List<Object?>) return const [];
  final Set<String> ids = <String>{};
  for (final Object? item in root['data']! as List<Object?>) {
    if (item is! Map<String, Object?>) continue;
    final Object? relationships = item['relationships'];
    if (relationships is! Map<String, Object?>) continue;
    final Object? videos = relationships['videos'];
    if (videos is! Map<String, Object?>) continue;
    final Object? data = videos['data'];
    if (data is! List<Object?>) continue;
    for (final Object? video in data) {
      if (video is Map<String, Object?> && video['id'] is String) {
        ids.add(video['id']! as String);
      }
    }
  }
  return ids.toList(growable: false);
}

List<TidalVideo> _tryVideo(Map<String, Object?> item) {
  if (item['type'] != 'videos' || item['id'] is! String) return const [];
  final Object? attributes = item['attributes'];
  if (attributes is! Map<String, Object?> || attributes['title'] is! String) {
    return const [];
  }
  return [
    TidalVideo(
      id: item['id']! as String,
      title: attributes['title']! as String,
      duration: _parseIsoDuration(attributes['duration']),
    ),
  ];
}

TidalVideo? _bestVideo(List<TidalVideo> candidates, SwayveTrack track) {
  TidalVideo? best;
  double bestScore = 0;
  for (final TidalVideo candidate in candidates) {
    final double score = _matchScore(candidate, track);
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best;
}

double _matchScore(TidalVideo candidate, SwayveTrack track) {
  final String wanted = _normalize(track.title);
  final String found = _normalize(candidate.title);
  if (wanted.isEmpty || found.isEmpty) return 0;

  final bool titleMatches = wanted == found ||
      found.contains(wanted) ||
      wanted.contains(found) ||
      _tokenOverlap(wanted, found) >= 0.7;
  if (!titleMatches) return 0;

  if (track.duration != null && candidate.duration != null) {
    final Duration difference = track.duration! - candidate.duration!;
    if (difference.abs() > kDurationTolerance) return 0;
  }

  double score = wanted == found ? 100 : 80;
  if (track.duration != null && candidate.duration != null) {
    score += 20 -
        (track.duration! - candidate.duration!).abs().inSeconds.clamp(0, 20);
  }
  return score;
}

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'\([^)]*\)|\[[^]]*\]'), ' ')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

double _tokenOverlap(String left, String right) {
  final Set<String> a =
      left.split(' ').where((String s) => s.isNotEmpty).toSet();
  final Set<String> b =
      right.split(' ').where((String s) => s.isNotEmpty).toSet();
  if (a.isEmpty || b.isEmpty) return 0;
  return a.intersection(b).length / a.union(b).length;
}

Duration? _parseIsoDuration(Object? value) {
  if (value is! String) return null;
  final RegExpMatch? match = RegExp(
    r'^P(?:(\d+)D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$',
  ).firstMatch(value);
  if (match == null) return null;
  final double seconds = (double.tryParse(match.group(1) ?? '0') ?? 0) * 86400 +
      (double.tryParse(match.group(2) ?? '0') ?? 0) * 3600 +
      (double.tryParse(match.group(3) ?? '0') ?? 0) * 60 +
      (double.tryParse(match.group(4) ?? '0') ?? 0);
  return Duration(microseconds: (seconds * 1000000).round());
}

String? _isrcFrom(SwayveTrack track) {
  for (final String key in <String>['isrc', 'ISRC']) {
    final Object? value = track.extra[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

Map<String, Object?> _object(Object? value, String path) {
  if (value is Map<String, Object?>) return value;
  throw SwayvePluginMalformedResponseException(
    'TIDAL response field $path was not an object.',
  );
}

String _string(Object? value, String path) {
  if (value is String && value.isNotEmpty) return value;
  throw SwayvePluginMalformedResponseException(
    'TIDAL response field $path was not a non-empty string.',
  );
}
