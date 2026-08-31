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
const Version kYouTubeMusicPluginVersion = Version(0, 3, 0);

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
  // Where the *editorial* cover art lives. A curated YouTube Music playlist
  // — the "'80s Rock" and "Chill Hits" shelves the home page is built out of
  // — publishes its sleeve here rather than on `lh3`, and so do artist
  // avatars. Verified against two real playlist browses: every thumbnail on
  // both, header and rows alike, was on this host.
  //
  // Without it declared, `YouTubeMusicArtwork` drops those images on the
  // floor — correctly, since handing the host a URL the manifest does not
  // cover is a silently broken image — and a wall of curated playlists draws
  // as a wall of placeholders. Declared here and in the manifest together, so
  // the permission screen shows it before anybody agrees to it.
  'yt3.googleusercontent.com',
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

/// The InnerTube endpoint that answers "what plays after this".
///
/// The same host search and browse are asked on, and the same `WEB_REMIX`
/// envelope: a radio is a music-app concept and the music front end is what
/// serves it. See `providers/radio_provider.dart`.
final Uri kNextEndpoint = Uri.parse('$kMusicOrigin/youtubei/v1/next');

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
final Uri kVisitorEndpoint = Uri.parse('$kWatchOrigin/youtubei/v1/visitor_id');

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

/// One InnerTube client identity, as a set of fields rather than a name.
///
/// A context naming a client without the device it belongs to is one
/// InnerTube may simply stop recognising — see [kPlayerDeviceMake] — so the
/// device half travels with the name instead of being remembered separately
/// at each call site. The device fields are nullable because they are only
/// worth sending when they were part of what was actually measured to work:
/// see [kCaptionsClients].
final class YouTubeMusicClientIdentity {
  /// Creates a client identity.
  const YouTubeMusicClientIdentity({
    required this.name,
    required this.id,
    required this.version,
    this.deviceMake,
    this.deviceModel,
    this.osName,
    this.osVersion,
  });

  /// The InnerTube `clientName`.
  final String name;

  /// The numeric client id, sent as `x-youtube-client-name`.
  final String id;

  /// The `clientVersion`, and the `x-youtube-client-version` header.
  final String version;

  /// The device this identity claims to be, when it claims one.
  final String? deviceMake;
  final String? deviceModel;
  final String? osName;
  final String? osVersion;

  @override
  String toString() => 'YouTubeMusicClientIdentity($name $version)';
}

/// The clients the *captions* half of a player response is asked as, in the
/// order they are tried.
///
/// ## Why captions are asked for at all, and why per client
///
/// A caption track list arrives on the player response, so asking for lyrics
/// means asking the player endpoint — and the player endpoint answers
/// differently per client. This list is declared separately from
/// [kPlayerClientName] so the captions identity stays independently
/// changeable: the streaming client is chosen for the one property that it
/// hands back media URLs already signed, which has nothing to do with
/// captions, and a future replacement for it should not silently become the
/// lyrics client by accident.
///
/// **Leading with the same client as streaming is deliberate, not an
/// accident of that separation.** [kPlayerClientName] is the identity this
/// plugin already depends on for every second of playback, which makes it
/// both the one most likely to keep working and — much more usefully — the
/// one whose failure is impossible to miss. A captions-only client can be
/// turned down and lyrics just quietly stop existing, because "no captions"
/// is the ordinary answer for most recordings and looks like nothing at all.
/// If the shared client goes, playback breaks first and loudly.
///
/// ## Why a chain rather than one client
///
/// Because the alternatives are visibly decaying. `ANDROID_VR` answered
/// perfectly when this was written and yt-dlp dropped it from its default
/// client list in 2026.08.19 after months of misbehaviour — its defaults are
/// `visionos,web` now. A single client is a single point of failure whose
/// failure mode here is silence.
///
/// ## Why not `WEB`
///
/// Because it does not answer. Measured against the live endpoint: `WEB` — on
/// the current client version read out of a real `music.youtube.com` page,
/// with and without a freshly minted visitor identity, and with the page's
/// own `INNERTUBE_CONTEXT` sent verbatim — came back `UNPLAYABLE` / "The page
/// needs to be reloaded" and **no `captions` block at all**. That is the
/// browser clients' attestation wall, the same one [kPlayerClientName]
/// documents: it cannot be climbed without running Google's own JavaScript.
/// `MWEB`, `TVHTML5` and `WEB_EMBEDDED_PLAYER` failed the same way.
///
/// Every entry below answered `OK` with six caption tracks for the same
/// video, in the same session, and each is sent as exactly the context that
/// was measured — which is why only the first carries device fields.
const List<YouTubeMusicClientIdentity> kCaptionsClients =
    <YouTubeMusicClientIdentity>[
  // The streaming client. First for the reason above.
  YouTubeMusicClientIdentity(
    name: kPlayerClientName,
    id: kPlayerClientId,
    version: kPlayerClientVersion,
    deviceMake: kPlayerDeviceMake,
    deviceModel: kPlayerDeviceModel,
    osName: kPlayerOsName,
    osVersion: kPlayerOsVersion,
  ),
  // Second rather than first precisely because it is on the way out.
  YouTubeMusicClientIdentity(
    name: 'ANDROID_VR',
    id: '28',
    version: '1.62.27',
  ),
  YouTubeMusicClientIdentity(name: 'IOS', id: '5', version: '20.11.6'),
];

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

/// The id of the `include_videos` setting, identical to `plugin.json`.
// Snake case because the manifest schema requires it of every setting id
// (`^[a-z][a-z0-9_]*$`), and `test/manifest_agreement_test.dart` compares
// this constant against the manifest rather than trusting them to match.
const String kIncludeVideosSettingId = 'include_videos';

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

/// The id of the `session_cookie` setting, identical to `plugin.json`.
///
/// A `type: "secret"` setting rather than a `string` one: its value goes to
/// the credential store, never to plugin settings, and is read back with
/// `context.credentials.readSecret`, not `settings.value`. See
/// `providers/auth_provider.dart`.
const String kSessionCookieSettingId = 'session_cookie';

/// The id of the `page_id` setting, identical to `plugin.json`.
///
/// Also a `type: "secret"` setting, for the same reason [kSessionCookieSettingId]
/// is — it identifies which of possibly several YouTube channels under one
/// Google account to act as, which is not something a stored cookie alone
/// settles. See `providers/library_provider.dart` for what happens without
/// it: nothing wrong, just the account's *default* channel, which is right
/// for the common case and wrong for anyone whose Liked Music lives on a
/// secondary channel.
const String kPageIdSettingId = 'page_id';

/// The InnerTube request header [kPageIdSettingId]'s value is sent as.
const String kPageIdHeader = 'x-goog-pageid';

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

  /// The signed-in user's personalized "Mixed for you" feed.
  ///
  /// Signed in only, and not gracefully: measured against the live endpoint,
  /// an anonymous browse of this id answers **HTTP 401**, "You must be signed
  /// in to perform this operation" — not an empty feed and not the
  /// "sign in" placeholder [likedSongs] answers with. Nothing may send it
  /// without a session cookie in hand; see
  /// `providers/catalog_provider.dart`.
  static const String mixedForYou = 'FEmusic_mixed_for_you';

  /// YouTube Music's mood and genre directory.
  ///
  /// **Two hops, not one.** Measured against the live endpoint: this browse
  /// carries no playlists at all. It answers with two `gridRenderer`s of
  /// `musicNavigationButtonRenderer` chips — "Moods & moments" and "Genres" —
  /// and every one of them carries the *same* browse id,
  /// [moodsAndGenresCategory], distinguished only by an opaque `params`.
  /// Browsing a chip's params is what actually returns playlists. See
  /// `parsing/mood_parser.dart` and `providers/playlist_provider.dart`.
  static const String moodsAndGenres = 'FEmusic_moods_and_genres';

  /// The browse id every mood/genre chip points at. Meaningless without the
  /// chip's own `params`.
  static const String moodsAndGenresCategory =
      'FEmusic_moods_and_genres_category';

  /// The browse id for the signed-in user's own saved and created playlists.
  ///
  /// Signed out it answers 200 with YouTube Music's "Looking for what
  /// you've liked?" sign-in placeholder — the same shape `looksSignedOut`
  /// already recognises for [likedSongs], confirmed against the live
  /// endpoint.
  static const String likedPlaylists = 'FEmusic_liked_playlists';

  /// The browse id for the signed-in user's own "Liked Music" playlist.
  ///
  /// `LM` is the reserved playlist id unofficial YouTube Music clients
  /// (`ytmusicapi` among them) use for a user's liked songs, and this
  /// plugin's own [YouTubeMusicIds.playlistBrowseId] already encodes the same
  /// `VL`-prefixing rule every other playlist browse in this plugin goes
  /// through — `playlistBrowseId('LM')` and this constant name the same
  /// string. Confirmed against real signed-in accounts, including a
  /// multi-channel one — see `providers/library_provider.dart`.
  static const String likedSongs = 'VLLM';
}

/// The pieces of a radio request that are not the seed.
///
/// A station is asked for on the `next` endpoint by naming a video and a
/// *radio playlist id* built out of it. The prefixes are YouTube Music's own
/// and are not derivable from anything else, which is why they are constants
/// rather than string literals at a call site.
abstract final class YouTubeMusicRadio {
  /// The prefix that turns a video id into "radio seeded by this recording".
  static const String videoSeedPrefix = 'RDAMVM';

  /// The prefix that turns a playlist or album id into "radio seeded by this
  /// collection".
  static const String collectionSeedPrefix = 'RDAMPL';

  /// The opaque `params` blob the web app sends when it starts a radio.
  static const String seedParams = 'wAEB';

  /// The radio playlist id for a video seed.
  static String forVideo(String videoId) => '$videoSeedPrefix$videoId';

  /// The radio playlist id for an album or playlist seed.
  ///
  /// [bareId] must already have had any `VL` browse prefix taken off — see
  /// `YouTubeMusicIds.barePlaylistId`. `VL` is how a playlist is *browsed*,
  /// not part of its id, and `RDAMPLVLPL…` is not a station.
  static String forCollection(String bareId) => '$collectionSeedPrefix$bareId';

  /// Whether [id] already names a station, in which case it is forwarded
  /// verbatim rather than wrapped again.
  static bool isStation(String id) => id.startsWith('RD');
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

/// How this plugin presents itself as a *place a query can be sent*, identical
/// to `plugin.json`'s `source`.
///
/// A constant here rather than left to the manifest alone for the same reason
/// every other value in this file is one: the manifest is what a person
/// approves at import, this is what runs, and `manifest_agreement_test.dart`
/// compares them. It also gives the plugin something to republish — a running
/// plugin is the only thing that can honestly say whether YouTube Music is
/// answering right now, and [SwayveSourceDescriptor.copyWith] with a new
/// availability is how it would say so.
///
/// [SwayveContentType.videos] is declared because this plugin genuinely
/// answers for them: the `include_videos` setting searches the upload half of
/// YouTube alongside the licensed catalogue, and that half is where the remix,
/// the demo, the live version and the unreleased track live — very often as
/// the only copy in existence. A host that could not offer videos as their own
/// filter would either bury a known release under nine covers of it or drop
/// the upload catalogue entirely, and the second is the same as telling
/// somebody a song they can hear right now does not exist.
const SwayveSourceDescriptor kYouTubeMusicSource = SwayveSourceDescriptor(
  sourceId: 'youtube_music',
  displayName: kYouTubeMusicPluginName,
  iconName: 'youtube_music',
  contentTypes: <SwayveContentType>{
    SwayveContentType.songs,
    SwayveContentType.albums,
    SwayveContentType.artists,
    SwayveContentType.videos,
  },
  capabilities: <SwayveCapability>{
    SwayveCapability.search,
    SwayveCapability.catalog,
    SwayveCapability.streaming,
    SwayveCapability.webview,
    SwayveCapability.artwork,
    SwayveCapability.authentication,
    SwayveCapability.personalLibrary,
    SwayveCapability.sessionCapture,
    SwayveCapability.metadataSearch,
    SwayveCapability.radio,
    SwayveCapability.playlistRead,
    SwayveCapability.lyrics,
  },
  supportedHosts: kYouTubeMusicMetadataSearchHosts,
);

/// The website hostnames [YouTubeMusicMetadataSearchProvider.resolveUrl]
/// answers for — every shape a person could plausibly paste in, not just
/// the one [kMusicOrigin] uses. `youtube.com`/`youtu.be` are covered
/// because a track that lives only as a video upload is just as often
/// linked from plain YouTube as from the Music front end, and the two
/// serve the same catalogue behind one video id.
const Set<String> kYouTubeMusicMetadataSearchHosts = <String>{
  'music.youtube.com',
  'www.youtube.com',
  'youtube.com',
  'youtu.be',
};
