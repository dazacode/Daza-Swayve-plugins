import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';

/// What a YouTube Music identifier refers to.
enum YouTubeMusicIdKind {
  /// A watchable recording, identified by a video id.
  track,

  /// A release, identified by an `MPRE`-prefixed browse id.
  album,

  /// A channel, identified by a `UC`-prefixed browse id.
  artist,

  /// A playlist, identified by a `VL`/`PL`/`RD`/`OLAK` browse id.
  playlist,
}

/// Reading and minting the provider-native identifiers this plugin puts in
/// `SwayveMediaId.value`.
///
/// `SwayveMediaId.value` holds YouTube Music's **own** id, unwrapped and
/// unprefixed — a video id such as `dQw4w9WgXcQ`, a browse id such as
/// `MPREb_4pLmZ8Wq6Xu`. The host never parses it (principle 2), but this
/// plugin has to: `SwayveCatalogProvider.album` receives nothing but an id and
/// must decide what to fetch.
///
/// Classification is by YouTube's own id shapes rather than by a private
/// prefix scheme, because those shapes are already disjoint and already
/// stable: browse ids are namespaced by a leading token, and a video id is
/// exactly eleven base64url characters. An id whose shape matches nothing is
/// not an error — it is an id this provider did not mint, and every entry
/// point treats it that way.
abstract final class YouTubeMusicIds {
  static final RegExp _videoId = RegExp(r'^[A-Za-z0-9_-]{11}$');

  /// The kind [value] denotes, or `null` when it is not one of ours.
  ///
  /// **The video shape is tested first, and that order is load-bearing.** A
  /// video id is any eleven base64url characters, which means a perfectly
  /// ordinary one can begin with the same letters a browse id is namespaced by
  /// — `PLxKq2n8Qm4`, `RDh1sT0pQwZ`, `UCn3dK9wVbX` are all valid, playable
  /// recordings. Checking the prefixes first classified those as playlists and
  /// artists, and every consequence of that was silent: the stream provider
  /// refused to play them because they were "not a track", the artwork provider
  /// spent a browse request on an id no browse would ever resolve, and a song
  /// that reached a track list simply stopped working when it was tapped.
  ///
  /// Testing the shape first cannot make the opposite mistake. A browse id is
  /// never eleven characters — `MPRE` release ids are seventeen, `UC` channel
  /// ids twenty-four, `PL` and `OLAK` playlist ids thirty-four and up — so the
  /// eleven-character window belongs to video ids alone.
  static YouTubeMusicIdKind? classify(String value) {
    if (value.isEmpty) return null;
    if (_videoId.hasMatch(value)) return YouTubeMusicIdKind.track;
    if (value.startsWith('MPRE')) return YouTubeMusicIdKind.album;
    if (value.startsWith('UC')) return YouTubeMusicIdKind.artist;
    if (value.startsWith('VL') ||
        value.startsWith('PL') ||
        value.startsWith('RD') ||
        value.startsWith('OLAK')) {
      return YouTubeMusicIdKind.playlist;
    }
    return null;
  }

  /// The kind [id] denotes, or `null` when [id] belongs to another plugin or
  /// has an unrecognised shape.
  static YouTubeMusicIdKind? kindOf(SwayveMediaId id) =>
      id.pluginId == kYouTubeMusicPluginId ? classify(id.value) : null;

  /// Whether [id] was minted by this plugin and denotes [kind].
  static bool isKind(SwayveMediaId id, YouTubeMusicIdKind kind) =>
      kindOf(id) == kind;

  /// Wraps a provider-native [value] as a Swayve media id owned by this
  /// plugin.
  static SwayveMediaId mediaId(String value) =>
      SwayveMediaId(kYouTubeMusicPluginId, value);

  /// The browse id to send for a playlist [value], with exactly one `VL`
  /// prefix on it.
  ///
  /// YouTube Music browses a playlist under a `VL`-prefixed id while linking
  /// to it under its bare `PL`/`OLAK`/`RDCLAK` id. Normalizing here keeps
  /// that quirk out of the providers.
  ///
  /// **Strip, then add — never "prepend unless it is already there".** The
  /// ids this is handed come from three places that disagree about the
  /// prefix: a `browseEndpoint` in a response arrives already `VL`-prefixed,
  /// a `playlistId` on a watch endpoint arrives bare, and a `SwayveMediaId`
  /// the host hands back may be either, because it is whichever of the two
  /// this plugin happened to mint it from. Feeding an already-prefixed id
  /// through a naive prepend produces `VLVLPL…`, which InnerTube answers
  /// with a 400 — and feeding it through this twice is a no-op, which is the
  /// property the call sites actually rely on.
  static String playlistBrowseId(String value) => 'VL${barePlaylistId(value)}';

  /// [value] with every leading `VL` browse prefix taken off.
  ///
  /// Safe to loop: no YouTube playlist id begins with `VL` — they begin with
  /// `PL`, `OLAK`, `RD`, `LM`, `UU`, `FL` or `SR` — so the only `VL` a value
  /// can carry is the browse prefix, however many times it has been applied.
  static String barePlaylistId(String value) {
    String bare = value;
    while (bare.startsWith('VL')) {
      bare = bare.substring(2);
    }
    return bare;
  }
}
