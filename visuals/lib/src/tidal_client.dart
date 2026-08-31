import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'errors.dart';

/// Finds TIDAL's animated cover for a recording.
///
/// An animated cover is the sleeve with a few seconds of motion in it — what
/// a label uploads alongside the still artwork, and what this plugin exists
/// to put behind a now-playing screen. It is an **album** asset, not a track
/// one: every track on a release shares the same moving cover.
///
/// This deliberately does not touch TIDAL's video-manifest endpoint, which an
/// earlier version of this plugin used. That endpoint serves *music videos* —
/// a different thing, several minutes long, meant to be watched rather than
/// looked past — and reaching it needs the `playback` scope, which requires a
/// subscriber authorisation flow this plugin has no business running. TIDAL
/// also restricts playback of its signed HLS/DASH manifests to its own player
/// SDK. An animated cover has none of those problems: it is a plain
/// progressive MP4 on a public CDN.
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

  /// Searches the official v2 catalog for an animated cover, using a bearer
  /// token minted from the plugin's TIDAL application credentials.
  ///
  /// Returns null — not an error — when the official catalog describes the
  /// release but names no animated cover for it. That is the expected answer
  /// for most releases, and it is also the answer if this API turns out not
  /// to expose the asset at all, in which case the legacy source behind this
  /// one carries the feature unchanged.
  Future<SwayveVisual?> officialCover(
    SwayveTrack track, {
    required String accessToken,
    SwayveCancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();

    final String query = _query(track);
    if (query.isEmpty) return null;

    final Map<String, Object?>? body = await _getOfficial(
      kTidalApiOrigin.replace(
        path: '/v2/searchResults/${Uri.encodeComponent(query)}',
        queryParameters: <String, String>{
          'countryCode': region,
          'include': 'albums',
        },
      ),
      accessToken: accessToken,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();
    if (body == null) return null;

    final _TidalCover? best = _bestCover(_officialCoversFrom(body), track);
    if (best == null) return null;
    return _visualFor(best);
  }

  /// Animated-cover candidates from a JSON:API `included` block.
  ///
  /// TIDAL's v2 API compounds related resources into `included` rather than
  /// nesting them. Only album resources are read, and only the ones that
  /// actually carry a cover id.
  List<_TidalCover> _officialCoversFrom(Map<String, Object?> body) {
    final Object? included = body['included'];
    if (included is! List<Object?>) return const <_TidalCover>[];
    final List<_TidalCover> found = <_TidalCover>[];
    for (final Object? resource in included) {
      if (resource is! Map<String, Object?>) continue;
      if (resource['type'] != 'albums') continue;
      final Object? attributes = resource['attributes'];
      if (attributes is! Map<String, Object?>) continue;

      final String? coverId = _officialCoverId(attributes);
      if (coverId == null) continue;

      final Object? title = attributes['title'];
      found.add(
        _TidalCover(
          videoCover: coverId,
          albumTitle: title is String ? title : '',
          trackTitle: null,
          // v2 puts artists in `relationships`, which this does not resolve.
          // An empty list makes the artist guard stand aside rather than
          // reject, and the album-title comparison still has to agree.
          artists: const <String>[],
        ),
      );
    }
    return found;
  }

  /// The animated-cover id inside a v2 album's attributes, if it has one.
  ///
  /// Two spellings are accepted because the v2 catalog is versioned
  /// separately from this plugin: the legacy field name, and the JSON:API
  /// `imageLinks`-style list where a cover is one entry among the artwork.
  String? _officialCoverId(Map<String, Object?> attributes) {
    final Object? direct = attributes['videoCover'];
    if (direct is String && direct.trim().isNotEmpty) return direct.trim();

    for (final String key in const <String>['videoLinks', 'coverArt']) {
      final Object? links = attributes[key];
      if (links is! List<Object?>) continue;
      for (final Object? link in links) {
        if (link is! Map<String, Object?>) continue;
        final Object? id = link['id'] ?? link['href'] ?? link['url'];
        if (id is! String || id.trim().isEmpty) continue;
        final String candidate = id.trim();
        if (animatedCoverUri(candidate) != null) return candidate;
      }
    }
    return null;
  }

  /// Searches the legacy catalog for an album whose animated cover matches
  /// [track], or returns null when there is none.
  Future<SwayveVisual?> legacyCover(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();

    final String query = _query(track);
    if (query.isEmpty) return null;

    final Map<String, Object?>? body = await _getLegacy(
      kTidalLegacyApiOrigin.replace(
        path: '/v1/search',
        queryParameters: <String, String>{
          'query': query,
          'limit': '10',
          'types': 'TRACKS,ALBUMS',
          'countryCode': region,
        },
      ),
      cancel: cancel,
    );
    cancel?.throwIfCancelled();
    if (body == null) return null;

    final _TidalCover? best = _bestCover(_coversFrom(body), track);
    if (best == null) return null;
    return _visualFor(best);
  }

  /// Every animated-cover candidate a legacy search response describes.
  ///
  /// Both shelves are read. An `ALBUMS` hit carries `videoCover` directly; a
  /// `TRACKS` hit carries the album it belongs to, which is where a track
  /// search finds the same asset. Asking for both in one request costs
  /// nothing extra and catches the common case where the album title is not
  /// what somebody would have typed.
  List<_TidalCover> _coversFrom(Map<String, Object?> body) {
    final List<_TidalCover> found = <_TidalCover>[];
    for (final Object? album in _items(body['albums'])) {
      final _TidalCover? cover = _albumCover(album, trackTitle: null);
      if (cover != null) found.add(cover);
    }
    for (final Object? item in _items(body['tracks'])) {
      if (item is! Map<String, Object?>) continue;
      final _TidalCover? cover = _albumCover(
        item['album'],
        trackTitle: item['title'] is String ? item['title']! as String : null,
        durationSeconds: item['duration'],
        artistsOverride: item['artists'],
      );
      if (cover != null) found.add(cover);
    }
    return found;
  }

  _TidalCover? _albumCover(
    Object? album, {
    required String? trackTitle,
    Object? durationSeconds,
    Object? artistsOverride,
  }) {
    if (album is! Map<String, Object?>) return null;
    final Object? videoCover = album['videoCover'];
    if (videoCover is! String || videoCover.trim().isEmpty) return null;

    final Object? title = album['title'];
    return _TidalCover(
      videoCover: videoCover.trim(),
      albumTitle: title is String ? title : '',
      trackTitle: trackTitle,
      artists: _artistNames(artistsOverride ?? album['artists']),
      duration: durationSeconds is int
          ? Duration(seconds: durationSeconds)
          : durationSeconds is num
              ? Duration(seconds: durationSeconds.toInt())
              : null,
    );
  }

  SwayveVisual? _visualFor(_TidalCover cover) {
    final Uri? uri = animatedCoverUri(cover.videoCover);
    if (uri == null) return null;
    if (!isAllowedHost(uri.host)) {
      throw SwayvePluginUnsupportedException(
        'The visuals plugin will not hand back media from ${uri.host}: it is '
        'not in the manifest allowlist.',
      );
    }
    return SwayveVisual(
      uri: uri,
      kind: SwayveVisualKind.motionArtwork,
      source: 'TIDAL',
      loops: true,
      // Every animated cover TIDAL serves at this path is square. Saying so
      // matters twice over: the host lays the surface out before a byte
      // arrives, and iOS refuses to install animated artwork whose aspect
      // ratio it was not told in advance.
      aspectRatio: 1,
    );
  }

  Future<Map<String, Object?>?> _getLegacy(
    Uri endpoint, {
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
        'accept': 'application/json',
        'x-tidal-token': kTidalLegacyClientToken,
        'user-agent': kUserAgent,
      },
      timeout: timeouts.request,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();
    if (response.statusCode == 404) return null;
    if (!response.isSuccess) {
      throw exceptionForStatus(response.statusCode, headers: response.headers);
    }
    final Object? decoded = response.bodyAsJson;
    if (decoded is! Map<String, Object?>) {
      throw SwayvePluginMalformedResponseException(
        'TIDAL returned a JSON document instead of an object.',
      );
    }
    return decoded;
  }

  Future<Map<String, Object?>?> _getOfficial(
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
      throw exceptionForStatus(response.statusCode, headers: response.headers);
    }
    final Object? decoded = response.bodyAsJson;
    if (decoded is! Map<String, Object?>) {
      throw SwayvePluginMalformedResponseException(
        'TIDAL returned a JSON document instead of an object.',
      );
    }
    return decoded;
  }

  String _query(SwayveTrack track) {
    final String artists = track.artistsLabel.trim();
    final String title = track.title.trim();
    final String query = <String>[
      if (title.isNotEmpty) title,
      if (artists.isNotEmpty) artists,
    ].join(' ');
    return query.length > 256 ? query.substring(0, 256) : query;
  }
}

/// Builds the CDN address of an animated cover from its id.
///
/// TIDAL serves these under the id's five hyphen-separated groups as path
/// segments. An id that is not in that shape is not one of these, and the
/// right answer is no visual rather than a guessed URL.
Uri? animatedCoverUri(String videoCover, {int edge = kAnimatedCoverEdge}) {
  final List<String> parts = videoCover.trim().split('-');
  if (parts.length != 5 || parts.any((String part) => part.isEmpty)) {
    return null;
  }
  final RegExp hex = RegExp(r'^[0-9a-fA-F]+$');
  if (parts.any((String part) => !hex.hasMatch(part))) return null;
  return kTidalResourcesOrigin.replace(
    pathSegments: <String>['videos', ...parts, '${edge}x$edge.mp4'],
  );
}

/// One animated-cover candidate, reduced to what matching needs.
final class _TidalCover {
  const _TidalCover({
    required this.videoCover,
    required this.albumTitle,
    required this.artists,
    this.trackTitle,
    this.duration,
  });

  /// The cover id, in TIDAL's five-group form.
  final String videoCover;

  /// The album this cover belongs to.
  final String albumTitle;

  /// The track title, when this candidate came from the tracks shelf.
  final String? trackTitle;

  /// The credited artist names, normalised at comparison time.
  final List<String> artists;

  /// The track duration, when the candidate came from the tracks shelf.
  final Duration? duration;
}

List<Object?> _items(Object? shelf) {
  if (shelf is! Map<String, Object?>) return const <Object?>[];
  final Object? items = shelf['items'];
  return items is List<Object?> ? items : const <Object?>[];
}

List<String> _artistNames(Object? artists) {
  if (artists is! List<Object?>) return const <String>[];
  return <String>[
    for (final Object? artist in artists)
      if (artist is Map<String, Object?> && artist['name'] is String)
        artist['name']! as String,
  ];
}

_TidalCover? _bestCover(List<_TidalCover> candidates, SwayveTrack track) {
  _TidalCover? best;
  double bestScore = 0;
  for (final _TidalCover candidate in candidates) {
    final double score = _matchScore(candidate, track);
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best;
}

/// How well [candidate] answers [track], or zero when it must not be used.
///
/// Conservative on purpose, and more so than a music-video match had to be.
/// A wrong music video is a wrong video; a wrong animated cover is the wrong
/// *sleeve* moving behind the right song, which reads as a bug rather than a
/// near miss. So an artist has to agree before anything else is considered.
double _matchScore(_TidalCover candidate, SwayveTrack track) {
  final String wantedArtist = _normalize(track.artistsLabel);
  if (wantedArtist.isNotEmpty && candidate.artists.isNotEmpty) {
    final bool artistAgrees = candidate.artists.any((String name) {
      final String found = _normalize(name);
      if (found.isEmpty) return false;
      return wantedArtist == found ||
          wantedArtist.contains(found) ||
          found.contains(wantedArtist) ||
          _tokenOverlap(wantedArtist, found) >= 0.5;
    });
    if (!artistAgrees) return 0;
  }

  // A tracks-shelf candidate names the recording itself, so it can be held to
  // the track title. An albums-shelf candidate cannot: the album is very
  // often not named after the song, and requiring that would throw away the
  // majority of correct answers.
  final String? candidateTrack = candidate.trackTitle;
  if (candidateTrack != null) {
    final String wanted = _normalize(track.title);
    final String found = _normalize(candidateTrack);
    if (wanted.isNotEmpty && found.isNotEmpty) {
      final bool titleMatches = wanted == found ||
          found.contains(wanted) ||
          wanted.contains(found) ||
          _tokenOverlap(wanted, found) >= 0.7;
      if (!titleMatches) return 0;
      final Duration? wantedLength = track.duration;
      final Duration? foundLength = candidate.duration;
      if (wantedLength != null && foundLength != null) {
        if ((wantedLength - foundLength).abs() > kDurationTolerance) return 0;
      }
      double score = wanted == found ? 100 : 80;
      if (wantedLength != null && foundLength != null) {
        score += 20 - (wantedLength - foundLength).abs().inSeconds.clamp(0, 20);
      }
      return score;
    }
  }

  // An album hit with an agreeing artist. Ranked below any track hit, because
  // a track hit proved the recording is on that release and this only proves
  // the artist has a release with a moving cover.
  final String wantedAlbum = _normalize(track.album?.title ?? '');
  final String foundAlbum = _normalize(candidate.albumTitle);
  if (wantedAlbum.isNotEmpty && foundAlbum.isNotEmpty) {
    if (wantedAlbum == foundAlbum) return 70;
    if (foundAlbum.contains(wantedAlbum) || wantedAlbum.contains(foundAlbum)) {
      return 60;
    }
    if (_tokenOverlap(wantedAlbum, foundAlbum) >= 0.6) return 50;
    // The track named an album and this is a different one. Declining is the
    // whole point of knowing the album name.
    return 0;
  }
  return 0;
}

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
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
