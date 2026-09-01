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
/// `open.spotify.com` mints the web-player access token and reports server
/// time, `api.spotify.com` resolves a recording to a Spotify track URI,
/// `spclient.wg.spotify.com` answers the canvas lookup, and `*.scdn.co`
/// serves the canvas video itself. As with TIDAL, the Spotify entries are
/// spelled out rather than wildcarded at the apex so a look-alike domain such
/// as `spotify.com.evil.example` is not admitted.
const List<String> kVisualsAllowedHosts = <String>[
  'openapi.tidal.com',
  '*.tidal.com',
  'open.spotify.com',
  'api.spotify.com',
  'spclient.wg.spotify.com',
  '*.scdn.co',
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

/// The secret setting holding the Spotify `sp_dc` session cookie.
///
/// A real logged-in session cookie, which is why it is a `secret` setting and
/// why the canvas source is off until somebody deliberately provides one.
/// See this plugin's README for what that grant actually is and why the
/// plugin never asks for it on anybody's behalf.
const String kSpotifySpDcSettingId = 'spotify_sp_dc';

/// The optional setting overriding the embedded TOTP secret version.
///
/// Exists so a rotation can be survived by typing a number rather than by
/// waiting for a plugin release. Empty means "use the embedded version".
const String kSpotifyTotpVersionSettingId = 'spotify_totp_version';

/// Where the web player mints its access token.
final Uri kSpotifyTokenEndpoint =
    Uri.parse('https://open.spotify.com/api/token');

/// Spotify's own clock, used so a device with a skewed clock still produces
/// a code the server accepts.
final Uri kSpotifyServerTimeEndpoint =
    Uri.parse('https://open.spotify.com/api/server-time');

/// The public Web API, used only to resolve a recording to a track URI.
final Uri kSpotifySearchEndpoint =
    Uri.parse('https://api.spotify.com/v1/search');

/// The canvas lookup. Speaks protobuf in both directions.
final Uri kSpotifyCanvasEndpoint =
    Uri.parse('https://spclient.wg.spotify.com/canvaz-cache/v0/canvases');

/// The origin the token endpoint expects its callers to declare.
const String kSpotifyWebOrigin = 'https://open.spotify.com';

/// The user-agent sent to the web endpoints.
///
/// A browser string rather than this plugin's own, and the one place in this
/// plugin where that is true. The token endpoint is the web player's, not a
/// documented API, and it answers a request that does not look like a browser
/// with an error rather than a token. Declaring `Swayve-Visuals` here would
/// be more honest and would simply not work.
const String kSpotifyWebUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, '
    'like Gecko) Chrome/127.0.0.0 Safari/537.36';

/// How many search hits to weigh before giving up on a match.
const int kSpotifySearchLimit = 10;

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
