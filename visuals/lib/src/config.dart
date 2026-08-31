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
/// wildcard covers the HTTPS media host returned by an official video
/// manifest without permitting a look-alike domain such as
/// `tidal.com.evil.example`.
const List<String> kVisualsAllowedHosts = <String>[
  'openapi.tidal.com',
  '*.tidal.com',
  'api.music.apple.com',
];

/// The secret setting containing the TIDAL OAuth access token.
const String kTidalAccessTokenSettingId = 'tidal_access_token';

/// The Apple Music developer token setting.
const String kAppleMusicDeveloperTokenSettingId = 'apple_music_developer_token';

/// The Apple Music storefront setting, for example `us`.
const String kAppleMusicStorefrontSettingId = 'apple_music_storefront';

/// Official TIDAL API origin.
final Uri kTidalApiOrigin = Uri.parse('https://openapi.tidal.com');

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
