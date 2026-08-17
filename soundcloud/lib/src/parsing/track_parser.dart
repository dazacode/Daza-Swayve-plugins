import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../ids.dart';
import '../json_path.dart';
import 'artwork.dart';

/// Whether a track object carries more than a bare id — the signal that
/// separates a hydrated track from a stub inside a playlist's `tracks` array.
///
/// SoundCloud returns a full object for every track in a short playlist, but
/// switches to `{"id": 123, "kind": "track"}` stubs for entries past its own
/// internal size threshold. A stub has no `title`; nothing else in the shape
/// is a reliable enough signal, since a legitimately empty-titled edge case
/// is not one SoundCloud actually produces.
bool isTrackStub(Map<String, Object?> json) => stringAt(json, ['title']) == null;

/// The bare numeric id of a (possibly stub) track object, or `null`.
int? trackStubId(Map<String, Object?> json) => intAt(json, ['id']);

/// Turns one SoundCloud track object into a [SwayveTrack], or `null` when
/// [json] is a stub with no title to show — a caller with stubs to hydrate
/// should do that first via `SoundCloudClient.hydrateStubs` and only reach
/// this parser with full objects.
SwayveTrack? parseTrack(Map<String, Object?> json) {
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

  final bool streamable = boolAt(json, ['streamable'], orElse: true);
  final String policy = stringAt(json, ['policy']) ?? 'ALLOW';
  final bool blocked = policy == 'BLOCK';
  final bool downloadable = boolAt(json, ['downloadable']);

  return SwayveTrack(
    id: SoundCloudIds.track(id),
    title: title,
    artists: artists,
    duration: _durationOf(json),
    year: _yearOf(json),
    artwork: SoundCloudArtwork.build(
          stringAt(json, ['artwork_url']),
          SwayveArtworkSize.medium,
        ) ??
        SoundCloudArtwork.build(
          stringAt(user, ['avatar_url']),
          SwayveArtworkSize.medium,
        ),
    explicit: boolAt(json, ['publisher_metadata', 'explicit']),
    availability: SwayveAvailability(
      streamable: streamable && !blocked,
      downloadable: downloadable,
    ),
    extra: <String, Object?>{
      if (stringAt(json, ['permalink_url']) case final String url) 'permalinkUrl': url,
      if (stringAt(json, ['genre']) case final String genre) 'genre': genre,
      if (intAt(json, ['playback_count']) case final int count) 'playbackCount': count,
      'policy': policy,
    },
  );
}

/// Unwraps one item of a SoundCloud `/charts` collection.
///
/// Observed chart payloads wrap each entry as `{"score": ..., "track": {...}}`
/// alongside a popularity score; this endpoint's exact envelope has not been
/// exercised against live traffic (see the plugin README), so a bare track
/// object is also accepted as a fallback rather than assumed impossible.
Map<String, Object?> unwrapChartItem(Object? item) {
  final Map<String, Object?> json = mapOf(item);
  final Map<String, Object?> wrapped = mapOf(json['track']);
  return wrapped.isNotEmpty ? wrapped : json;
}

/// Parses every full (non-stub) track object in [items], skipping anything
/// that is not a well-formed track object rather than failing the whole
/// list — one bad row costs one row, per the parser's "total navigation"
/// rule.
List<SwayveTrack> parseTrackList(Iterable<Object?> items) {
  final List<SwayveTrack> tracks = <SwayveTrack>[];
  for (final Object? item in items) {
    final Map<String, Object?> json = mapOf(item);
    if (json.isEmpty) continue;
    final SwayveTrack? track = parseTrack(json);
    if (track != null) tracks.add(track);
  }
  return tracks;
}

Duration? _durationOf(Map<String, Object?> json) {
  final int? millis = intAt(json, ['duration']);
  return millis == null ? null : Duration(milliseconds: millis);
}

int? _yearOf(Map<String, Object?> json) {
  final String? date =
      stringAt(json, ['release_date']) ?? stringAt(json, ['created_at']);
  if (date == null || date.length < 4) return null;
  return int.tryParse(date.substring(0, 4));
}
