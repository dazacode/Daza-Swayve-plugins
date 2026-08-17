import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../parsing/track_parser.dart';
import '../soundcloud_client.dart';

/// SoundCloud's answer to `SwayveArtistActivityProvider`. Capability:
/// `artist_activity`.
///
/// Both methods are real, live-verified feeds, not stubs:
///
/// * [likedTracks] reads `/users/{id}/likes` — confirmed live to mix liked
///   tracks and liked playlists in one collection, each wrapped as
///   `{"track": {...}}` or `{"playlist": {...}}`.
/// * [repostedTracks] reads `/stream/users/{id}/reposts` — confirmed live to
///   mix `track-repost` and `playlist-repost` entries, each carrying its own
///   `type`.
///
/// Both are filtered to tracks only here, matching this plugin's audio-only,
/// tracks-only scope everywhere else (see `SoundCloudCatalogProvider` and
/// `SoundCloudPlaylistProvider`): a liked or reposted *playlist* is silently
/// dropped rather than surfaced or treated as an error, the same "one bad
/// row costs one row" rule [parseTrackList] already applies.
///
/// Both take the *artist's* media id — a [SoundCloudIdKind.user] — and
/// return an empty, cursor-less page for any other kind or a foreign id,
/// without making a request, mirroring `SoundCloudPlaylistProvider
/// .playlistTracks`'s guard for the same reason: the return type is a
/// non-nullable `SwayvePage`, so "no such artist" and "wrong kind of id" both
/// answer with nothing to show rather than an exception.
final class SoundCloudArtistActivityProvider
    implements SwayveArtistActivityProvider {
  /// Creates a provider over [client].
  SoundCloudArtistActivityProvider({
    required SoundCloudClient client,
    this.timeouts = SoundCloudTimeouts.manifest,
  }) : _client = client;

  final SoundCloudClient _client;

  /// The deadlines this provider works to.
  final SoundCloudTimeouts timeouts;

  @override
  Future<SwayvePage<SwayveTrack>> likedTracks(
    SwayveMediaId artistId,
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'likedTracks',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          if (!SoundCloudIds.isKind(artistId, SoundCloudIdKind.user)) {
            return const SwayvePage<SwayveTrack>();
          }
          final int numeric = SoundCloudIds.numericValue(artistId)!;
          final SoundCloudPage page = await _client.userLikes(
            numeric,
            cursor: request.cursor,
            cancel: cancel,
          );
          final List<Object?> unwrapped = <Object?>[
            for (final Object? item in page.items) unwrapChartItem(item),
          ];
          return SwayvePage<SwayveTrack>(
            items: parseTrackList(unwrapped),
            cursor: page.nextHref,
          );
        },
      );

  @override
  Future<SwayvePage<SwayveTrack>> repostedTracks(
    SwayveMediaId artistId,
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'repostedTracks',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          if (!SoundCloudIds.isKind(artistId, SoundCloudIdKind.user)) {
            return const SwayvePage<SwayveTrack>();
          }
          final int numeric = SoundCloudIds.numericValue(artistId)!;
          final SoundCloudPage page = await _client.userReposts(
            numeric,
            cursor: request.cursor,
            cancel: cancel,
          );
          final List<Object?> unwrapped = <Object?>[
            for (final Object? item in page.items)
              if (isTrackRepost(item)) unwrapChartItem(item),
          ];
          return SwayvePage<SwayveTrack>(
            items: parseTrackList(unwrapped),
            cursor: page.nextHref,
          );
        },
      );
}
