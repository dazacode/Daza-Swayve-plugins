import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// Raises the right plugin exception for a TIDAL HTTP status.
SwayvePluginException exceptionForStatus(
  int statusCode, {
  Map<String, String> headers = const <String, String>{},
}) {
  if (statusCode == 401) {
    return const SwayvePluginAuthRequiredException(
      'TIDAL rejected the access token.',
    );
  }
  if (statusCode == 403) {
    return const SwayvePluginUnavailableException(
      'TIDAL refused access to this visual.',
    );
  }
  if (statusCode == 429) {
    return SwayvePluginRateLimitedException(
      'TIDAL rate limited the visual lookup.',
      retryAfter: _retryAfter(headers['retry-after']),
    );
  }
  if (statusCode >= 500) {
    return SwayvePluginUnavailableException(
      'TIDAL returned HTTP $statusCode.',
    );
  }
  return SwayvePluginUnavailableException(
    'TIDAL returned HTTP $statusCode.',
  );
}

Duration? _retryAfter(String? value) {
  if (value == null) return null;
  final int? seconds = int.tryParse(value.trim());
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}
