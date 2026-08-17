import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../json_path.dart';
import '../parsing/playlist_parser.dart';
import '../soundcloud_client.dart';

/// SoundCloud's answer to `SwayvePlaylistProvider`. Capability:
/// `playlist_read`.
///
/// Included deliberately, unlike the YouTube Music reference plugin: YT Music
/// folds playlists into "album" browse ids because that's how its own web UI
/// treats them, but SoundCloud's data model keeps `is_album` playlists (real
/// releases, handled by `SoundCloudCatalogProvider`) and plain playlists
/// (mixes, "liked tracks"-style sets, DJ mixes) genuinely distinct. Forcing a
/// plain playlist into `SwayveAlbum` would misrepresent it as a release the
/// SDK has a dedicated capability for exactly this case, so it's used.
///
/// [playlists] shares its feed with `SoundCloudCatalogProvider.albums` —
/// `/playlists/discovery`, unfiltered here rather than filtered to
/// `is_album: true` — with the same live-traffic caveat documented there.
/// [playlistTracks] is a real, working lookup regardless of that: fetch the
/// playlist, hydrate any stubbed tracks past SoundCloud's own size threshold,
/// and return them in playlist order.
final class SoundCloudPlaylistProvider implements SwayvePlaylistProvider {
  /// Creates a provider over [client].
  SoundCloudPlaylistProvider({
    required SoundCloudClient client,
    this.timeouts = SoundCloudTimeouts.manifest,
  }) : _client = client;

  final SoundCloudClient _client;

  /// The deadlines this provider works to.
  final SoundCloudTimeouts timeouts;

  @override
  Future<SwayvePage<SwayvePlaylist>> playlists(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'playlists',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final SoundCloudPage page = await _client.playlistDiscovery(
            cursor: request.cursor,
            cancel: cancel,
          );
          final List<SwayvePlaylist> playlists = <SwayvePlaylist>[
            for (final Object? item in page.items)
              if (parsePlaylistEnvelope(mapOf(item)) case final envelope?)
                if (!envelope.isAlbum) playlistFromEnvelope(envelope),
          ];
          return SwayvePage<SwayvePlaylist>(
            items: playlists,
            cursor: page.nextHref,
          );
        },
      );

  @override
  Future<SwayvePage<SwayveTrack>> playlistTracks(
    SwayveMediaId id,
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'playlistTracks',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          if (!SoundCloudIds.isKind(id, SoundCloudIdKind.playlist)) {
            return const SwayvePage<SwayveTrack>();
          }
          final int numeric = SoundCloudIds.numericValue(id)!;
          final Map<String, Object?>? json =
              await _client.playlist(numeric, cancel: cancel);
          if (json == null) return const SwayvePage<SwayveTrack>();
          final ParsedPlaylistEnvelope? envelope = parsePlaylistEnvelope(json);
          if (envelope == null) return const SwayvePage<SwayveTrack>();
          cancel?.throwIfCancelled();
          final List<SwayveTrack> tracks =
              await _client.hydratePlaylistTracks(envelope, cancel: cancel);
          // SoundCloud's `full` playlist representation returns the entire
          // `tracks` array in one response — stubs and all — rather than
          // paging it with its own `next_href`, so hydration (bounded at
          // `kMaxHydrationBatches * kTrackBatchSize`, several hundred tracks)
          // is the whole answer for one lookup; no separate cursor to offer.
          return SwayvePage<SwayveTrack>(items: tracks);
        },
      );
}
