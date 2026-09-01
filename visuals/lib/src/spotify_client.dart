import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'canvas_protobuf.dart';
import 'config.dart';
import 'errors.dart';
import 'matching.dart';
import 'spotify_auth.dart';

/// Finds the canvas Spotify holds for a recording.
///
/// ## Two requests, because the host does not deal in Spotify ids
///
/// The canvas endpoint is keyed on a `spotify:track:…` URI, and the SDK
/// deliberately never hands a visuals provider an id from somebody else's
/// catalogue — `SwayveVisualsProvider.visual` takes a whole `SwayveTrack`
/// precisely because the service holding the video is usually not the service
/// the track came from. So this resolves the recording itself first, through
/// the public search API, and only then asks about the URI it found.
///
/// That first hop is where nearly all the risk of a wrong answer lives, which
/// is why the match runs through the shared rules in `matching.dart` rather
/// than trusting search rank. A canvas is chosen to sit behind a specific
/// song; the wrong one is more obviously wrong than a generic animated cover
/// would be.
final class SpotifyCanvasClient {
  /// Creates a client over the host-mediated HTTP transport.
  SpotifyCanvasClient({
    required SwayveHttpClient http,
    required SpotifyTokenSource tokens,
    this.timeouts = VisualsTimeouts.manifest,
  })  : _http = http,
        _tokens = tokens;

  final SwayveHttpClient _http;
  final SpotifyTokenSource _tokens;

  /// The per-request budget.
  final VisualsTimeouts timeouts;

  /// The canvas for [track], or `null` when Spotify has none for it.
  ///
  /// Null covers three ordinary outcomes that are not worth distinguishing to
  /// a caller whose fallback is identical in all of them: the recording was
  /// not found, it was found but no candidate matched well enough, or it
  /// matched and simply has no canvas. Most tracks have no canvas — they are
  /// made per release by the artist, not generated — so null is the common
  /// answer here, not the failure case.
  Future<SwayveVisual?> canvas(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  }) async {
    final String token = await _tokens.token(cancel: cancel);
    cancel?.throwIfCancelled();

    final String? trackUri = await _resolveTrackUri(
      track,
      accessToken: token,
      cancel: cancel,
    );
    if (trackUri == null) return null;
    cancel?.throwIfCancelled();

    final List<CanvasEntry> entries = await _canvases(
      trackUri,
      accessToken: token,
      cancel: cancel,
    );
    if (entries.isEmpty) return null;

    // Only one URI was asked about, so any entry naming a different track is
    // a response this does not understand rather than a near miss to accept.
    // An entry with no track URI at all is fine: the field is optional and
    // there was only ever one thing it could refer to.
    for (final CanvasEntry entry in entries) {
      if (entry.trackUri.isNotEmpty && entry.trackUri != trackUri) continue;
      final Uri? uri = Uri.tryParse(entry.canvasUrl);
      if (uri == null || !uri.hasScheme) continue;
      if (!isAllowedHost(uri.host)) {
        throw SwayvePluginUnsupportedException(
          'The visuals plugin will not hand back media from ${uri.host}: it '
          'is not in the manifest allowlist.',
        );
      }
      return SwayveVisual(
        uri: uri,
        kind: SwayveVisualKind.motionArtwork,
        source: 'Spotify',
        // A canvas is a few seconds long by construction and is meant to run
        // for as long as the song does. Looping is the entire format.
        loops: true,
        // Canvases are authored portrait, 9:16, the shape of the phone screen
        // they were designed to fill. Reported rather than discovered because
        // the host lays its surface out before a byte arrives.
        aspectRatio: 9 / 16,
      );
    }
    return null;
  }

  /// The `spotify:track:…` URI for [track], or null when nothing matched.
  Future<String?> _resolveTrackUri(
    SwayveTrack track, {
    required String accessToken,
    SwayveCancellationToken? cancel,
  }) async {
    final String query = _searchQuery(track);
    if (query.isEmpty) return null;

    final Uri endpoint = kSpotifySearchEndpoint.replace(
      queryParameters: <String, String>{
        'q': query,
        'type': 'track',
        'limit': '$kSpotifySearchLimit',
      },
    );

    final Map<String, Object?>? body = await _getJson(
      endpoint,
      accessToken: accessToken,
      cancel: cancel,
    );
    if (body == null) return null;

    final Object? tracks = body['tracks'];
    if (tracks is! Map<String, Object?>) return null;
    final Object? items = tracks['items'];
    if (items is! List<Object?>) return null;

    String? best;
    double bestScore = 0;
    for (final Object? item in items) {
      if (item is! Map<String, Object?>) continue;
      final Object? uri = item['uri'];
      if (uri is! String || !uri.startsWith('spotify:track:')) continue;

      final double score = _score(track, item);
      if (score > bestScore) {
        bestScore = score;
        best = uri;
      }
    }
    return best;
  }

  /// How well a search hit matches the recording, or 0 to reject it.
  double _score(SwayveTrack track, Map<String, Object?> item) {
    final Object? name = item['name'];
    if (name is! String || name.trim().isEmpty) return 0;
    if (!titlesAgree(track.title, name)) return 0;

    final List<String> artists = <String>[
      for (final Object? artist
          in (item['artists'] as List<Object?>? ?? const <Object?>[]))
        if (artist is Map<String, Object?> && artist['name'] is String)
          artist['name']! as String,
    ];
    if (!artistsAgree(track.artistsLabel, artists)) return 0;

    final Object? millis = item['duration_ms'];
    final Duration? found = millis is int
        ? Duration(milliseconds: millis)
        : millis is num
            ? Duration(milliseconds: millis.toInt())
            : null;
    if (!durationsAgree(track.duration, found)) return 0;

    // Past the gates, prefer an exact title and then the closest running
    // time. Search rank deliberately contributes nothing: Spotify ranks by
    // popularity, which is how a hit single's radio edit wins over the album
    // version somebody is actually playing.
    double score =
        normalizeForMatch(track.title) == normalizeForMatch(name) ? 100 : 80;
    final Duration? wanted = track.duration;
    if (wanted != null && found != null) {
      score += 20 - (wanted - found).abs().inSeconds.clamp(0, 20);
    }
    return score;
  }

  /// The canvases Spotify holds for [trackUri].
  Future<List<CanvasEntry>> _canvases(
    String trackUri, {
    required String accessToken,
    SwayveCancellationToken? cancel,
  }) async {
    if (!isAllowedHost(kSpotifyCanvasEndpoint.host)) {
      throw SwayvePluginUnsupportedException(
        'The visuals plugin will not contact ${kSpotifyCanvasEndpoint.host}: '
        'it is not in the manifest allowlist.',
      );
    }

    final SwayveHttpResponse response = await _http.post(
      kSpotifyCanvasEndpoint,
      headers: <String, String>{
        'accept': 'application/protobuf',
        'content-type': 'application/x-protobuf',
        'accept-language': 'en',
        'authorization': 'Bearer $accessToken',
        'user-agent': kUserAgent,
      },
      body: encodeCanvasRequest(<String>[trackUri]),
      timeout: timeouts.request,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    if (response.statusCode == 401) {
      _tokens.invalidate();
      throw const SwayvePluginAuthRequiredException(
        'Spotify rejected the access token for the canvas lookup.',
      );
    }
    // 404 is how the endpoint says "no canvas here", which is the ordinary
    // answer for most recordings and not a failure to report.
    if (response.statusCode == 404) return const <CanvasEntry>[];
    if (!response.isSuccess) {
      throw exceptionForStatus(response.statusCode, headers: response.headers);
    }
    if (response.bodyBytes.isEmpty) return const <CanvasEntry>[];

    return decodeCanvasResponse(response.bodyBytes);
  }

  Future<Map<String, Object?>?> _getJson(
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
        'accept': 'application/json',
        'authorization': 'Bearer $accessToken',
        'user-agent': kUserAgent,
      },
      timeout: timeouts.request,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    if (response.statusCode == 401) {
      _tokens.invalidate();
      throw const SwayvePluginAuthRequiredException(
        'Spotify rejected the access token for the catalogue search.',
      );
    }
    if (response.statusCode == 404) return null;
    if (!response.isSuccess) {
      throw exceptionForStatus(response.statusCode, headers: response.headers);
    }

    final Object? decoded = response.bodyAsJson;
    return decoded is Map<String, Object?> ? decoded : null;
  }
}

/// The query sent to Spotify's search for [track].
///
/// Field-qualified rather than free text: `track:` and `artist:` narrow the
/// index far more sharply than the same words loose, which matters because
/// only the first [kSpotifySearchLimit] hits are ever weighed. Quotation
/// marks are stripped rather than escaped — they are query syntax here, and
/// a title containing one would otherwise change what is being asked.
String _searchQuery(SwayveTrack track) {
  final String title = _queryTerm(track.title);
  if (title.isEmpty) return '';
  final String artist = _queryTerm(track.artistsLabel);
  return artist.isEmpty ? 'track:$title' : 'track:$title artist:$artist';
}

String _queryTerm(String value) {
  final String cleaned = value
      .replaceAll(RegExp(r'["\\]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned.isEmpty ? '' : '"$cleaned"';
}
