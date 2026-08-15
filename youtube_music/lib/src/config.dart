/// Everything this plugin knows about YouTube Music as constants.
///
/// Each value here has a counterpart in `plugin.json`, and
/// `test/manifest_agreement_test.dart` reads the manifest and asserts they
/// still agree. That test is the reason these are constants rather than
/// strings scattered through the client: a plugin whose code reaches a host
/// its manifest does not declare has escaped the permission model, and the
/// cheapest way to notice is to keep both halves in one place and compare
/// them.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// The plugin id, identical to `plugin.json`'s `id`.
///
/// Every `SwayveMediaId` this plugin mints carries it, which is how the host
/// routes a later request back here.
const String kYouTubeMusicPluginId = 'app.swayve.plugins.youtube_music';

/// The human-readable name, identical to `plugin.json`'s `name`.
const String kYouTubeMusicPluginName = 'YouTube Music';

/// The plugin version, identical to `plugin.json`'s `version`.
const Version kYouTubeMusicPluginVersion = Version(0, 1, 0);

/// The hostnames this plugin is permitted to reach, identical to
/// `plugin.json`'s `network.hosts`.
///
/// The host enforces this list; the plugin restates it so that
/// [isAllowedHost] can refuse to *build* a URL that would be rejected, and so
/// that the test suite can prove no code path ever tries.
const List<String> kYouTubeMusicAllowedHosts = <String>[
  'music.youtube.com',
  'www.youtube.com',
  'i.ytimg.com',
];

/// Whether [host] is covered by [kYouTubeMusicAllowedHosts].
///
/// Matching mirrors the manifest's own rule: an entry is either an exact
/// hostname or a single `*.` wildcard covering one or more leading labels.
/// Comparison is case-insensitive because hostnames are.
bool isAllowedHost(String host) {
  final String candidate = host.toLowerCase();
  for (final String pattern in kYouTubeMusicAllowedHosts) {
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

/// The origin every InnerTube request is made against.
const String kMusicOrigin = 'https://music.youtube.com';

/// The InnerTube endpoint that answers a search.
final Uri kSearchEndpoint = Uri.parse('$kMusicOrigin/youtubei/v1/search');

/// The InnerTube endpoint that answers a browse.
final Uri kBrowseEndpoint = Uri.parse('$kMusicOrigin/youtubei/v1/browse');

/// The InnerTube client identity YouTube Music's own web app uses.
///
/// `WEB_REMIX` is the web player; the numeric name `67` is its InnerTube
/// client id. The version string is the part most likely to age: InnerTube
/// tolerates a stale one for a long time and then stops, which is the single
/// most likely cause of a sudden `SwayvePluginUnavailableException` from an
/// otherwise healthy plugin.
const String kInnerTubeClientName = 'WEB_REMIX';

/// The numeric InnerTube client id matching [kInnerTubeClientName].
const String kInnerTubeClientId = '67';

/// The InnerTube client version this plugin presents.
const String kInnerTubeClientVersion = '1.20240403.01.00';

/// The default region, identical to the `region` setting's `default` in
/// `plugin.json`.
const String kDefaultRegion = 'US';

/// The id of the `region` setting, identical to `plugin.json`.
const String kRegionSettingId = 'region';

/// The deadlines this plugin works to.
///
/// [manifest] mirrors `plugin.json`'s `timeouts` block. Tests construct their
/// own with millisecond budgets so that proving a deadline fires does not cost
/// twenty seconds of wall clock.
final class YouTubeMusicTimeouts {
  /// Creates a timeout budget.
  const YouTubeMusicTimeouts({required this.request, required this.operation});

  /// The budgets declared in `plugin.json`.
  static const YouTubeMusicTimeouts manifest = YouTubeMusicTimeouts(
    request: Duration(milliseconds: 10000),
    operation: Duration(milliseconds: 20000),
  );

  /// The budget for one outbound HTTP request.
  final Duration request;

  /// The budget for one complete provider call, including every request it
  /// makes internally.
  final Duration operation;
}

/// The browse ids this plugin uses for paged catalogue listings.
///
/// A `SwayveSortOrder` is a hint, so an order YouTube Music has no feed for
/// falls back to the home feed rather than failing.
abstract final class YouTubeMusicFeeds {
  /// The personalized/home feed. The default listing.
  static const String home = 'FEmusic_home';

  /// The new-releases feed, used for `SwayveSortOrder.recent`.
  static const String newReleases = 'FEmusic_new_releases';

  /// The charts feed, used for `SwayveSortOrder.popular`.
  static const String charts = 'FEmusic_charts';
}

/// The InnerTube `params` blobs that scope a search to one kind of result.
///
/// These are the opaque, protobuf-derived filter tokens the web app sends when
/// the user picks a chip such as "Songs". They are only used when the host
/// asked for exactly one kind — see `YouTubeMusicSearchProvider`.
abstract final class YouTubeMusicSearchFilters {
  /// Songs only.
  static const String songs = 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D';

  /// Albums only.
  static const String albums = 'EgWKAQIYAWoKEAkQBRAKEAMQBA%3D%3D';

  /// Artists only.
  static const String artists = 'EgWKAQIgAWoKEAkQBRAKEAMQBA%3D%3D';

  /// Community playlists only.
  static const String playlists = 'EgeKAQQoAEABagoQAxAEEAoQCRAF';
}
