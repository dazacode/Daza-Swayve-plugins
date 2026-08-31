/// Constants shared by the visuals plugin and its manifest-agreement tests.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// The plugin id, identical to `plugin.json`.
const String kVisualsPluginId = 'app.swayve.plugins.visuals';

/// The plugin name, identical to `plugin.json`.
const String kVisualsPluginName = 'Moving Visuals';

/// The plugin version, identical to `plugin.json`.
const Version kVisualsPluginVersion = Version(0, 1, 0);

/// The hostnames this plugin may contact or hand back as playable media.
///
/// `openapi.tidal.com` is the official TIDAL Developer Platform API. The
/// wildcard covers `auth.tidal.com` (the OAuth token endpoint), the legacy
/// `api.tidal.com` catalog search, and `resources.tidal.com`, which serves
/// the animated cover itself — without permitting a look-alike domain such
/// as `tidal.com.evil.example`.
const List<String> kVisualsAllowedHosts = <String>[
  'openapi.tidal.com',
  '*.tidal.com',
];

/// The secret setting holding the TIDAL application's client id.
const String kTidalClientIdSettingId = 'tidal_client_id';

/// The secret setting holding the TIDAL application's client secret.
const String kTidalClientSecretSettingId = 'tidal_client_secret';

/// Official TIDAL API origin.
final Uri kTidalApiOrigin = Uri.parse('https://openapi.tidal.com');

/// The OAuth token endpoint that turns a client id and secret into a bearer
/// token. Covered by the `*.tidal.com` entry above.
final Uri kTidalTokenEndpoint =
    Uri.parse('https://auth.tidal.com/v1/oauth2/token');

/// The legacy catalog search, used only when the official API has no animated
/// cover to offer. See this plugin's README for why it is here at all.
final Uri kTidalLegacyApiOrigin = Uri.parse('https://api.tidal.com');

/// The shared client token the legacy catalog search requires.
///
/// Not a credential belonging to anybody: the legacy endpoint refuses a
/// request without this header, and the same value is what every open-source
/// client sends. It grants no account access and carries no user identity.
const String kTidalLegacyClientToken = 'vNVdglQOjFJJGG2U';

/// Where an animated cover is served from, once its id is known.
final Uri kTidalResourcesOrigin = Uri.parse('https://resources.tidal.com');

/// The square edge length requested for an animated cover.
///
/// TIDAL publishes 80, 160, 320, 640 and 1280. 1280 is roughly 700 KB for a
/// typical cover and is what the surface behind a now-playing screen wants;
/// anything smaller is visibly soft once it fills a phone.
const int kAnimatedCoverEdge = 1280;

/// The user-agent sent to TIDAL's official API.
const String kUserAgent =
    'Swayve-Visuals/0.1.0 (https://github.com/dazacode/Daza-Swayve-plugins)';

/// How long a single host-mediated TIDAL request may take.
const Duration kRequestTimeout = Duration(milliseconds: 10000);

/// How long one complete visual lookup may take, including fallback requests.
const Duration kOperationTimeout = Duration(milliseconds: 20000);

/// A conservative match window for audio and music-video durations.
///
/// Music videos often have a short intro or outro, but a much larger
/// difference usually means a remix, live performance or a wrong search hit.
const Duration kDurationTolerance = Duration(seconds: 20);

/// Whether [host] is covered by `network.hosts` in the manifest.
bool isAllowedHost(String host) {
  final String candidate = host.toLowerCase();
  for (final String pattern in kVisualsAllowedHosts) {
    if (pattern.startsWith('*.')) {
      final String suffix = pattern.substring(1).toLowerCase();
      if (candidate.endsWith(suffix) && candidate.length > suffix.length) {
        return true;
      }
    } else if (candidate == pattern.toLowerCase()) {
      return true;
    }
  }
  return false;
}

/// Per-call deadlines, injectable in tests.
final class VisualsTimeouts {
  /// Creates timeout budgets.
  const VisualsTimeouts({
    this.request = kRequestTimeout,
    this.operation = kOperationTimeout,
  });

  /// The manifest budgets.
  static const VisualsTimeouts manifest = VisualsTimeouts();

  /// Budget for one HTTP request.
  final Duration request;

  /// Budget for one provider operation.
  final Duration operation;
}
