import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../ids.dart';
import '../json_path.dart';
import 'artwork.dart';
import 'track_parser.dart';

/// Everything read off a SoundCloud `playlists` object, before the caller
/// decides whether to present it as a [SwayveAlbum] or a [SwayvePlaylist] and
/// before its track list (possibly containing stubs — see
/// [ParsedPlaylistEnvelope.rawTracks]) has been resolved to real
/// [SwayveTrack]s.
///
/// The same wire shape backs both `SwayveAlbum` and `SwayvePlaylist`; only
/// [isAlbum] decides which the caller builds. This mirrors
/// `SoundCloudIds`'s own reasoning: the *entity* is one thing, the *label*
/// SoundCloud currently puts on it is read fresh every time rather than
/// trusted from an id.
final class ParsedPlaylistEnvelope {
  const ParsedPlaylistEnvelope({
    required this.id,
    required this.title,
    required this.isAlbum,
    required this.artists,
    required this.year,
    required this.trackCount,
    required this.artwork,
    required this.description,
    required this.ownerName,
    required this.rawTracks,
  });

  /// The numeric SoundCloud playlist id.
  final int id;

  /// The playlist/album title. Never empty — [parsePlaylistEnvelope] returns
  /// `null` rather than an envelope with an empty title.
  final String title;

  /// SoundCloud's own `is_album` flag.
  final bool isAlbum;

  /// The credited artist(s) — the playlist's owning user.
  final List<SwayveArtistRef> artists;

  /// The release year, when [isAlbum] and a release date is known.
  final int? year;

  /// SoundCloud's own `track_count`, which may exceed [rawTracks].length for
  /// a playlist whose track listing is itself paged.
  final int? trackCount;

  /// Cover art. Falls back to the owning user's avatar when SoundCloud has
  /// not set one directly on the playlist — some playlists never had one
  /// uploaded, and a blank tile is a worse answer than the creator's face.
  final SwayveImageRef? artwork;

  /// A short description, when present.
  final String? description;

  /// The owning user's display name.
  final String? ownerName;

  /// The playlist's `tracks` array, unparsed. Each element is either a full
  /// track object or a stub (`{"id": ..., "kind": "track"}`) — see
  /// [isTrackStub]. The caller resolves stubs (via
  /// `SoundCloudClient.hydrateStubs`) and splices the result back into place
  /// with [spliceHydratedTracks] before building a final [SwayveTrack] list.
  final List<Object?> rawTracks;
}

/// Parses the envelope of a SoundCloud `playlists` object, or returns `null`
/// when [json] does not have the minimum shape of one (an id and a title).
ParsedPlaylistEnvelope? parsePlaylistEnvelope(Map<String, Object?> json) {
  final int? id = intAt(json, ['id']);
  final String? title = stringAt(json, ['title']);
  if (id == null || title == null) return null;

  final Map<String, Object?> user = mapAt(json, ['user']);
  final List<SwayveArtistRef> artists = <SwayveArtistRef>[];
  final int? userId = intAt(user, ['id']);
  final String? username = stringAt(user, ['username']);
  if (username != null) {
    artists.add(
      SwayveArtistRef(
        name: username,
        id: userId == null ? null : SoundCloudIds.user(userId),
      ),
    );
  }

  final bool isAlbum = boolAt(json, ['is_album']);

  return ParsedPlaylistEnvelope(
    id: id,
    title: title,
    isAlbum: isAlbum,
    artists: artists,
    year: isAlbum ? _yearOf(json) : null,
    trackCount: intAt(json, ['track_count']),
    artwork: SoundCloudArtwork.build(
          stringAt(json, ['artwork_url']),
          SwayveArtworkSize.medium,
        ) ??
        SoundCloudArtwork.build(
          stringAt(user, ['avatar_url']),
          SwayveArtworkSize.medium,
        ),
    description: stringAt(json, ['description']),
    ownerName: username,
    rawTracks: listAt(json, ['tracks']),
  );
}

/// Splices hydrated tracks back into [rawTracks]' original order.
///
/// A stub whose id is not a key of [hydrated] — because its batch failed to
/// hydrate, or it was never requested — is skipped rather than represented as
/// a broken row: "what has been gathered is a truer answer than a title-less
/// placeholder," the same reasoning `YouTubeMusicCatalogProvider._listing`
/// applies to a continuation that fails outright. A full (non-stub) entry is
/// parsed in place.
List<SwayveTrack> spliceHydratedTracks(
  List<Object?> rawTracks,
  Map<int, SwayveTrack> hydrated,
) {
  final List<SwayveTrack> result = <SwayveTrack>[];
  for (final Object? item in rawTracks) {
    final Map<String, Object?> json = mapOf(item);
    if (json.isEmpty) continue;
    if (isTrackStub(json)) {
      final int? id = trackStubId(json);
      final SwayveTrack? track = id == null ? null : hydrated[id];
      if (track != null) result.add(track);
      continue;
    }
    final SwayveTrack? track = parseTrack(json);
    if (track != null) result.add(track);
  }
  return result;
}

/// The numeric ids of every stub entry in [rawTracks], in order, deduplicated.
List<int> stubIdsIn(List<Object?> rawTracks) {
  final List<int> ids = <int>[];
  final Set<int> seen = <int>{};
  for (final Object? item in rawTracks) {
    final Map<String, Object?> json = mapOf(item);
    if (json.isEmpty || !isTrackStub(json)) continue;
    final int? id = trackStubId(json);
    if (id != null && seen.add(id)) ids.add(id);
  }
  return ids;
}

/// Builds a [SwayveAlbum] from [envelope] and its already-hydrated [tracks],
/// or `null` when [envelope] is not actually an album.
SwayveAlbum? albumFromEnvelope(
  ParsedPlaylistEnvelope envelope,
  List<SwayveTrack> tracks,
) {
  if (!envelope.isAlbum) return null;
  return SwayveAlbum(
    id: SoundCloudIds.playlist(envelope.id),
    title: envelope.title,
    artists: envelope.artists,
    year: envelope.year,
    trackCount: envelope.trackCount,
    artwork: envelope.artwork,
    availability: SwayveAvailability(streamable: tracks.isNotEmpty),
    tracks: tracks,
  );
}

/// Builds a [SwayvePlaylist] from [envelope].
SwayvePlaylist playlistFromEnvelope(ParsedPlaylistEnvelope envelope) =>
    SwayvePlaylist(
      id: SoundCloudIds.playlist(envelope.id),
      title: envelope.title,
      description: envelope.description,
      ownerName: envelope.ownerName,
      trackCount: envelope.trackCount,
      artwork: envelope.artwork,
    );

int? _yearOf(Map<String, Object?> json) {
  final String? date =
      stringAt(json, ['release_date']) ?? stringAt(json, ['created_at']);
  if (date == null || date.length < 4) return null;
  return int.tryParse(date.substring(0, 4));
}
