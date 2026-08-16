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
  // Where the square cover art lives. `i.ytimg.com` only publishes video
  // frames — 16:9, letterboxed, and stretched into a mess by anything that
  // draws a sleeve — so without this host the plugin can describe a song's
  // artwork but never its record's.
  //
  // Declared rather than assumed: this widens the network reach the user
  // granted, and it is listed in the manifest as well so that the permission
  // screen shows it before anybody agrees to it.
  'lh3.googleusercontent.com',
  // The media servers. A resolved audio URL points at a rotating edge host —
  // `rr2---sn-a5m7lnld.googlevideo.com` and the like — and the HLS fallback at
  // `manifest.googlevideo.com`, so the wildcard is the only honest way to
  // declare them: the specific hostname is chosen per request by YouTube and
  // is not knowable in advance.
  '*.googlevideo.com',
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

/// The origin the playback endpoints are asked against.
///
/// `www.youtube.com` rather than `music.youtube.com`, because the player
/// endpoint is YouTube's rather than YouTube Music's — the music front end
/// answers `UNPLAYABLE` for the client this plugin has to use. Both hosts are
/// declared in the manifest.
const String kWatchOrigin = 'https://www.youtube.com';

/// The InnerTube endpoint that resolves a video to its media streams.
final Uri kPlayerEndpoint = Uri.parse('$kWatchOrigin/youtubei/v1/player');

/// The InnerTube endpoint that mints a visitor identity.
///
/// See [InnerTubeClient.visitorData] for why every player request needs one.
final Uri kVisitorEndpoint =
    Uri.parse('$kWatchOrigin/youtubei/v1/visitor_id');

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

/// The InnerTube client the *player* endpoint is asked as.
///
/// ## Why this is a different client from [kInnerTubeClientName]
///
/// Search and browse are asked as `WEB_REMIX`, which is YouTube Music's own
/// web app and the right client for the music catalogue. It is the wrong
/// client for playback: it answers `UNPLAYABLE` on the player endpoint, and
/// the browser clients that do answer hand back media URLs whose signature has
/// to be reconstructed by executing a function out of a two-megabyte,
/// deliberately obfuscated `base.js`. There is no way to do that from a pure
/// Dart plugin with no JavaScript runtime, and the projects that do it in
/// other languages now shell out to a real JS engine because maintaining an
/// interpreter for it stopped being tractable.
///
/// `VISIONOS` is the one client that returns media URLs already signed: no
/// cipher to solve, no throttling parameter to unscramble, and no
/// proof-of-origin token — which cannot be obtained without running Google's
/// own attestation JavaScript, so any client that requires one is closed to
/// this plugin permanently.
///
/// ## What that means for how long this lasts
///
/// It is a door, and doors close. `ANDROID`, `IOS` and most recently
/// `ANDROID_VR` all used to work this way and no longer do. Everything about
/// this client is therefore a constant rather than a literal, so that
/// following it to whatever replaces it is an edit to this block — and
/// `YouTubeMusicStreamProvider` falls back to the embedded player rather than
/// failing when extraction stops working, so the day it closes the plugin
/// degrades instead of breaking.
const String kPlayerClientName = 'VISIONOS';

/// The numeric InnerTube client id matching [kPlayerClientName].
const String kPlayerClientId = '101';

/// The client version presented alongside [kPlayerClientName].
const String kPlayerClientVersion = '1.02';

/// The device this plugin claims to be when asking for playback.
///
/// Sent because the client identity is a set rather than a name: a context
/// naming the client without the device it belongs to is one InnerTube may
/// stop recognising, and these three cost nothing to send.
const String kPlayerDeviceMake = 'Apple';
const String kPlayerDeviceModel = 'RealityDevice17,1';
const String kPlayerOsName = 'visionOS';
const String kPlayerOsVersion = '26.5.23O471';

/// The client a visitor identity is minted as.
///
/// The plain web client, because that is what the endpoint expects and the
/// identity it returns is not client-specific.
const String kVisitorClientName = 'WEB';

/// The version presented when minting a visitor identity.
const String kVisitorClientVersion = '2.20260708.00.00';

/// How long a resolved media URL is treated as good for.
///
/// The player response states its own figure and this plugin passes that on;
/// this is the floor used when it says nothing. Six hours is what the `expire`
/// parameter on a live URL actually carries, and the margin below it exists
/// because the host re-resolves *after* the deadline rather than before.
const Duration kStreamLifetime = Duration(hours: 6);

/// Taken off a stated lifetime before it is handed to the host.
///
/// A URL that expires while a queue is being loaded, or while somebody is
/// reading a track list before pressing play, is a URL that was technically
/// valid when it was handed over and dead by the time it was used. Two minutes
/// is longer than any of those gaps and shorter than anything a listener would
/// notice as a needless re-resolution.
const Duration kStreamExpiryMargin = Duration(minutes: 2);

/// The largest body YouTube will serve at full speed.
///
/// Beyond roughly ten mebibytes in one response the media servers throttle to
/// a little above real-time playback — a deliberate measure, and one that
/// turns a three-second download into a two-minute one. Anything fetching a
/// whole file must ask for it in pieces no larger than this.
///
/// The SDK has nowhere to say this, and it deliberately should not: a chunk
/// size is a property of one service's edge servers, and a host that took
/// instructions about request shapes from a plugin would be letting the plugin
/// drive its transport. What the host does instead is chunk every plugin
/// download as a matter of policy, which is good manners against any service
/// and happens to be exactly what this one requires. This constant is what the
/// plugin's own tests measure that policy against.
const int kStreamChunkBytes = 10 * 1024 * 1024;

/// The id of the `includeVideos` setting, identical to `plugin.json`.
const String kIncludeVideosSettingId = 'includeVideos';

/// Whether video results are searched for when the setting says nothing.
///
/// On, because the music that is only on YouTube is the reason somebody adds
/// this plugin rather than using the catalogue they already have.
const bool kDefaultIncludeVideos = true;

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

  /// Videos only — the "Videos" chip.
  ///
  /// A different catalogue from [songs], and the reason this constant exists.
  /// The songs filter returns the official music catalogue: licensed releases,
  /// with an album behind them. An enormous amount of music is not in it —
  /// unreleased tracks, remixes, demos, live rips, edits, and everything an
  /// artist put on YouTube and nowhere else — and all of it is uploaded as a
  /// video. Searching only the catalogue means those songs simply do not exist
  /// as far as this plugin is concerned, however precisely somebody types the
  /// title.
  ///
  /// What comes back is a rougher class of result — no album, a 16:9 thumbnail
  /// rather than a sleeve, and a title somebody typed by hand — which is why
  /// the host is told which shelf each track came from rather than handed one
  /// merged list. See [kYouTubeKindKey].
  static const String videos = 'EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D';

  /// Albums only.
  static const String albums = 'EgWKAQIYAWoKEAkQBRAKEAMQBA%3D%3D';

  /// Artists only.
  static const String artists = 'EgWKAQIgAWoKEAkQBRAKEAMQBA%3D%3D';

  /// Community playlists only.
  static const String playlists = 'EgeKAQQoAEABagoQAxAEEAoQCRAF';
}
