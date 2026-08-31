import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';

/// Small client for Apple Music catalog music-video previews.
final class AppleMusicClient {
  AppleMusicClient({
    required SwayveHttpClient http,
    this.timeouts = VisualsTimeouts.manifest,
  }) : _http = http;

  final SwayveHttpClient _http;
  final VisualsTimeouts timeouts;

  Future<SwayveVisual?> visual(
    SwayveTrack track, {
    required String developerToken,
    required String storefront,
    SwayveCancellationToken? cancel,
  }) async {
    final query = <String, String>{
      'term': '${track.title} ${track.artists.firstOrNull?.name ?? ''}',
      'types': 'music-videos',
      'limit': '5',
    };
    final uri = Uri.parse(
      'https://api.music.apple.com/v1/catalog/${Uri.encodeComponent(storefront)}/search',
    ).replace(queryParameters: query);
    if (!isAllowedHost(uri.host)) {
      throw const SwayvePluginMalformedResponseException(
        'Apple Music visual endpoint is outside the declared allowlist.',
      );
    }
    final response = await _http
        .get(
          uri,
          headers: <String, String>{'Authorization': 'Bearer $developerToken'},
          cancel: cancel,
        )
        .timeout(timeouts.request);
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const SwayvePluginAuthRequiredException(
        'The Apple Music developer token was rejected.',
      );
    }
    if (response.statusCode != 200) return null;
    final root = response.bodyAsJson;
    if (root is! Map<String, Object?>) return null;
    final results = _map(root['results']);
    final videos = _list(results['music-videos']);
    for (final item in videos) {
      final attributes = _map(_map(item)['attributes']);
      final previews = _list(attributes['previews']);
      final preview = previews.map(_map).firstWhere(
            (entry) => entry['url'] is String,
            orElse: () => const <String, Object?>{},
          );
      final url = preview['url'];
      if (url is! String) continue;
      final visualUri = Uri.tryParse(url);
      if (visualUri == null || visualUri.scheme != 'https') continue;
      return SwayveVisual(
        uri: visualUri,
        kind: SwayveVisualKind.video,
        source: 'Apple Music',
        loops: true,
        duration: track.duration,
      );
    }
    return null;
  }

  Map<String, Object?> _map(Object? value) =>
      value is Map ? Map<String, Object?>.from(value) : const {};

  List<Object?> _list(Object? value) => value is List ? value : const [];
}
