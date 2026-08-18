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
bool isTrackStub(Map<String, Object?> json) =>
    stringAt(json, ['title']) == null;

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
  final String? permalinkUrl = stringAt(json, ['permalink_url']);

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
      if (stringAt(json, ['genre']) case final String genre) 'genre': genre,
      if (intAt(json, ['playback_count']) case final int count)
        'playbackCount': count,
      'policy': policy,
    },
    externalUrl: permalinkUrl == null ? null : Uri.tryParse(permalinkUrl),
    alternateNames: _alternateNamesOf(json, username: username),
  );
}

/// The other names SoundCloud already publishes for a track, out of the corner
/// of the payload this parser used to read one boolean from.
///
/// `publisher_metadata` is the rights holder's own view of a track, and it is
/// filled in whenever a release came through a distributor rather than straight
/// off somebody's laptop. Until now the parser read `explicit` from it and
/// nothing else, which meant the plugin was fetching the label's version of the
/// artist and the release title on every request and discarding both.
///
/// They are worth having because they are frequently *not* the same strings the
/// rest of the object carries. `user.username` is a SoundCloud handle — an
/// account name, chosen for a URL, often stylised or abbreviated — while
/// `publisher_metadata.artist` is the name the release was registered under.
/// `user.full_name` is a third spelling again. For a release in a non-Latin
/// script these routinely differ by script rather than by punctuation, so a
/// host holding all of them can find the song from any of them and a host
/// holding one cannot.
///
/// Nothing here is computed. `permalink` is a plausible-looking fourth
/// candidate — SoundCloud derives it from the title and it is ASCII by
/// construction, which makes it look like a free romanization — and it is
/// deliberately not read: it is a URL slug, hyphenated and lowercased and
/// truncated, and passing it off as a name the service published would be this
/// plugin guessing under a label that means it did not. `writer_composer` is
/// left alone for the same kind of reason: a composer credit is a different
/// person, not another name for this one.
SwayveAlternateNames _alternateNamesOf(
  Map<String, Object?> json, {
  required String? username,
}) {
  final String? publishedArtist =
      stringAt(json, ['publisher_metadata', 'artist']);
  final String? albumTitle =
      stringAt(json, ['publisher_metadata', 'album_title']);
  final String? releaseTitle =
      stringAt(json, ['publisher_metadata', 'release_title']);
  final String? fullName = stringAt(json, ['user', 'full_name']);

  final List<String> aliases = <String>[];
  void alias(String? candidate, String? alreadyKnownAs) {
    if (candidate == null || candidate.trim().isEmpty) return;
    final String name = candidate.trim();
    if (name == alreadyKnownAs?.trim() || aliases.contains(name)) return;
    aliases.add(name);
  }

  // The account's display name, when it is a different string from the handle
  // the track is credited to. A great many accounts set both to the same
  // thing, and one name stored twice is noise in every list that reads these.
  alias(fullName, username);
  // A release title that disagrees with the album title is a second name for
  // the same record — an edition, a market variant, a reissue — rather than a
  // correction of the first.
  alias(releaseTitle, albumTitle);

  return SwayveAlternateNames(
    // The registered credit goes in `originalArtist` rather than into the
    // aliases: it is specifically the name behind the handle, which is a
    // labelled relationship a host can show, and burying it in a free-form
    // list would throw that label away.
    originalArtist:
        publishedArtist != null && publishedArtist.trim() != username?.trim()
            ? publishedArtist
            : null,
    // The only release name a bare track object ever carries. `parseTrack`
    // sets no album at all — SoundCloud's track objects do not reference one,
    // and the album a track is filed under here is stamped later from the
    // playlist envelope it arrived in — so this is genuinely a name the song
    // goes by that nothing else in the row states.
    originalAlbum: albumTitle,
    aliases: aliases,
  );
}

/// Unwraps one item of a SoundCloud `/charts` collection — and, sharing the
/// same `{"track": {...}}` wrapper key, one item of `/users/{id}/likes` or
/// `/stream/users/{id}/reposts` too (both confirmed live).
///
/// Observed chart payloads wrap each entry as `{"score": ..., "track": {...}}`
/// alongside a popularity score; this endpoint's exact envelope has not been
/// exercised against live traffic (see the plugin README), so a bare track
/// object is also accepted as a fallback rather than assumed impossible. A
/// likes or reposts item that wraps a *playlist* instead (no `"track"` key)
/// falls back to the outer envelope, which has no `id`/`title` of its own —
/// [parseTrack] returns `null` for it, and [parseTrackList] drops it, which
/// is exactly the "tracks only" filtering those two feeds need.
Map<String, Object?> unwrapChartItem(Object? item) {
  final Map<String, Object?> json = mapOf(item);
  final Map<String, Object?> wrapped = mapOf(json['track']);
  return wrapped.isNotEmpty ? wrapped : json;
}

/// Whether [item] from `/stream/users/{id}/reposts` reposts a track, as
/// opposed to a playlist repost or any other activity-feed entry this
/// plugin's audio-only, tracks-only scope has no use for.
///
/// Judged by the envelope's own `type` field (`"track-repost"`, confirmed
/// live) when present; falls back to the nested entity's `kind` for a shape
/// that omits `type` altogether, the same "look at what's actually there
/// rather than assume a field exists" discipline [unwrapChartItem] follows.
bool isTrackRepost(Object? item) {
  final Map<String, Object?> json = mapOf(item);
  final String? type = stringAt(json, ['type']);
  if (type != null) return type == 'track-repost';
  return stringAt(json, ['track', 'kind']) == 'track';
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
