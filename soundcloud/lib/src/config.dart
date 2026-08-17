/// Everything this plugin knows about SoundCloud as constants.
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
const String kSoundCloudPluginId = 'app.swayve.plugins.soundcloud';

/// The human-readable name, identical to `plugin.json`'s `name`.
const String kSoundCloudPluginName = 'SoundCloud';

/// The plugin version, identical to `plugin.json`'s `version`.
const Version kSoundCloudPluginVersion = Version(0, 1, 0);

/// The hostnames this plugin is permitted to reach, identical to
/// `plugin.json`'s `network.hosts`.
///
/// The host enforces this list; the plugin restates it so that
/// [isAllowedHost] can refuse to *build* a URL that would be rejected, and so
/// that the test suite can prove no code path ever tries.
const List<String> kSoundCloudAllowedHosts = <String>[
  // Where the public `client_id` is scraped from. See
  // `SoundCloudClient.clientId` for why this has to be a page fetch rather
  // than a documented credential.
  'soundcloud.com',
  // The public v2 JSON API every other request goes through.
  'api-v2.soundcloud.com',
  // The script bundle host (where the scraped page's `<script>` tags point),
  // the `i1`-`i4.sndcdn.com` artwork/avatar CDN, and the media edge a
  // resolved stream URL points at. One wildcard covers all three because the
  // specific edge host is chosen per request and is not knowable in advance
  // — the same reasoning as the YouTube Music plugin's `*.googlevideo.com`.
  '*.sndcdn.com',
];

/// Whether [host] is covered by [kSoundCloudAllowedHosts].
///
/// Matching mirrors the manifest's own rule: an entry is either an exact
/// hostname or a single `*.` wildcard covering one or more leading labels.
/// Comparison is case-insensitive because hostnames are.
bool isAllowedHost(String host) {
  final String candidate = host.toLowerCase();
  for (final String pattern in kSoundCloudAllowedHosts) {
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

/// The public API origin every request except the `client_id` scrape and a
/// resolved media address is made against.
const String kApiOrigin = 'https://api-v2.soundcloud.com';

/// The page fetched to scrape a `client_id` from.
///
/// A fixed public track page rather than the site root: the root is more
/// likely to answer with a locale or consent interstitial that carries no
/// `client_id` at all, where a specific track page reliably renders the full
/// web client. Any long-lived public track would do; this one is SoundCloud's
/// own long-standing example track, chosen for the same reason
/// `sound-on-fire` picks a fixed page rather than the homepage.
final Uri kClientIdSourcePage = Uri.parse(
  'https://soundcloud.com/soundcloud/soundcloud-cross-platform-sdk-demo',
);

/// How many script tags [SoundCloudClient.clientId] will try before giving
/// up, taken from the end of the page's `<script src="...">` list.
///
/// The bundle carrying `client_id` is empirically the last app script on the
/// page, but a page that appends an unrelated analytics tag afterwards would
/// break a "last script only" scrape silently. Trying a bounded number from
/// the end recovers from that without scanning (and paying for) every script
/// on the page.
const int kClientIdScriptScanLimit = 6;

/// The `client_id:"..."` spelling `client_id` is embedded with in the web
/// bundle.
final RegExp kClientIdPatternColon = RegExp('client_id\\s*:\\s*"([^"]+)"');

/// The `client_id=...` query-string spelling, tried when the first pattern
/// does not match.
///
/// Both are checked because the exact form has drifted before across every
/// unofficial client that scrapes this value; trying two known spellings is
/// cheap insurance, not speculative generality.
final RegExp kClientIdPatternQuery = RegExp(r'client_id=([A-Za-z0-9]+)');

/// SoundCloud's own "no specific genre" urn, used when a chart or discovery
/// request has nothing more specific to ask for.
const String kAllMusicGenre = 'soundcloud:genres:all-music';

/// The discovery tag used when `catalog.albums()` or
/// `SoundCloudPlaylistProvider.playlists()` is asked for a listing with no
/// more specific request to narrow it — SoundCloud's own broadest discovery
/// shelf.
const String kDefaultDiscoveryTag = 'All Music';

/// The largest batch of ids sent to a single `/tracks?ids=` request.
///
/// SoundCloud's own batch endpoint caps around this figure; a longer request
/// is chunked rather than failed. Used both for search fan-out and for
/// hydrating stubbed playlist tracks.
const int kTrackBatchSize = 50;

/// How many hydration batches [SoundCloudClient.hydrateStubs] will fetch for
/// one playlist before giving up.
///
/// At [kTrackBatchSize] per batch this is several hundred tracks — longer
/// than any playlist worth calling one, so reaching it means something is
/// wrong (a batch that never shrinks the stub set) rather than that somebody
/// owns an unusually long playlist.
const int kMaxHydrationBatches = 10;

/// How many continuation pages a single playlist's own `tracks` listing will
/// follow when it is paged past a single response.
const int kMaxPlaylistListingPages = 10;

/// A conservative floor for how long a resolved media URL stays valid.
///
/// Unlike YouTube's player response, SoundCloud's media-resolution endpoint
/// states no expiry of its own in the payload — this is an assumption, not a
/// figure the API declares, and is documented as such rather than presented
/// as a stated contract. Observed signed URLs remain valid for roughly an
/// hour; this floor is comfortably inside that.
const Duration kStreamLifetime = Duration(minutes: 55);

/// Taken off [kStreamLifetime] before it is handed to the host, so a URL
/// handed over right at the boundary is not already stale by the time
/// playback starts.
const Duration kStreamExpiryMargin = Duration(minutes: 2);

/// The id of the `region` setting, identical to `plugin.json`.
const String kRegionSettingId = 'region';

/// The sentinel value meaning "no region filter" — the worldwide chart.
///
/// Not an empty string: the manifest schema requires every `select` option's
/// `value` to be at least one character, so the "Global" choice needs a real
/// token like every other option rather than a blank one.
const String kGlobalRegionValue = 'global';

/// The default region, identical to the manifest's declared default.
const String kDefaultRegion = kGlobalRegionValue;

/// The deadlines this plugin works to.
///
/// [manifest] mirrors `plugin.json`'s `timeouts` block. Tests construct their
/// own with millisecond budgets so that proving a deadline fires does not
/// cost twenty seconds of wall clock.
final class SoundCloudTimeouts {
  /// Creates a timeout budget.
  const SoundCloudTimeouts({required this.request, required this.operation});

  /// The budgets declared in `plugin.json`.
  static const SoundCloudTimeouts manifest = SoundCloudTimeouts(
    request: Duration(milliseconds: 10000),
    operation: Duration(milliseconds: 20000),
  );

  /// The budget for one outbound HTTP request.
  final Duration request;

  /// The budget for one complete provider call, including every request it
  /// makes internally — including, on the hydration path, several.
  final Duration operation;
}

/// The chart `kind` SoundCloud's `/charts` endpoint understands.
enum SoundCloudChartKind {
  /// Freshest first — SoundCloud's own "Trending" chart.
  trending,

  /// Most-played first — SoundCloud's own "Top" chart.
  top;

  /// The query-string spelling of this chart kind.
  String get wireName => name;
}

/// The chart [SoundCloudChartKind] that best serves [sort].
///
/// A `SwayveSortOrder` is a hint, so an order with no chart equivalent falls
/// back to `top` rather than failing — the same "an order with no feed falls
/// back rather than fails" rule `YouTubeMusicCatalogProvider.feedFor` follows.
SoundCloudChartKind chartKindFor(SwayveSortOrder? sort) => switch (sort) {
      SwayveSortOrder.recent => SoundCloudChartKind.trending,
      SwayveSortOrder.popular ||
      SwayveSortOrder.relevance ||
      SwayveSortOrder.alphabetical ||
      null =>
        SoundCloudChartKind.top,
    };
