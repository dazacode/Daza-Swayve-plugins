/// The one way out of this plugin.
///
/// Every request both sources make goes through here, which is what makes the
/// manifest's `network.hosts` list something the plugin obeys rather than
/// something the host merely enforces on it. The host would refuse an
/// undeclared hostname anyway; refusing it here as well means the refusal names
/// the plugin's own mistake, at the line that made it, instead of surfacing as
/// a failed lookup.
///
/// It is deliberately thin. There is no caching, no retry and no connection
/// state: a lyric lookup is one GET, the answer is the host's to remember if it
/// wants to, and a plugin that kept its own cache would be keeping it in memory
/// the host cannot see or reclaim.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';

/// A GET-only client over the host's [SwayveHttpClient].
final class LyricsClient {
  /// Creates a client over [http].
  LyricsClient({
    required SwayveHttpClient http,
    this.timeouts = LyricsTimeouts.manifest,
  }) : _http = http;

  final SwayveHttpClient _http;

  /// The deadlines this client works to.
  final LyricsTimeouts timeouts;

  /// GETs [endpoint] with [query] appended.
  ///
  /// Throws `SwayvePluginUnsupportedException` before making a request when
  /// [endpoint] is not on the manifest's allowlist. That is a programming
  /// error in this plugin rather than a service problem, and it is worth
  /// separating from one: the host's own refusal would arrive as a transport
  /// failure and read like an outage.
  ///
  /// Entries in [query] whose value is `null` are dropped, so a caller can pass
  /// the optional fields unconditionally and let the track decide which of them
  /// are actually known.
  Future<SwayveHttpResponse> get(
    Uri endpoint,
    Map<String, String?> query, {
    SwayveCancellationToken? cancel,
  }) {
    if (!isAllowedHost(endpoint.host)) {
      throw SwayvePluginUnsupportedException(
        'The lyrics plugin will not contact ${endpoint.host}: it is not one '
        'of the hosts declared in the plugin manifest.',
      );
    }
    final Uri url = endpoint.replace(
      queryParameters: <String, String>{
        for (final MapEntry<String, String?> entry in query.entries)
          if (entry.value != null && entry.value!.isNotEmpty)
            entry.key: entry.value!,
      },
    );
    return _http.get(
      url,
      headers: <String, String>{
        'accept': 'application/json',
        // The whole of this plugin's side of the bargain with two services
        // that ask for nothing else. See [kUserAgent].
        'user-agent': kUserAgent,
      },
      timeout: timeouts.request,
      cancel: cancel,
    );
  }
}
