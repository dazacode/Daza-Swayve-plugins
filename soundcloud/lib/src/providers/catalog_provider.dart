import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../json_path.dart';
import '../parsing/playlist_parser.dart';
import '../parsing/track_parser.dart';
import '../parsing/user_parser.dart';
import '../soundcloud_client.dart';

/// SoundCloud's answer to `SwayveCatalogProvider`. Capability: `catalog`.
///
/// **Listing** ([tracks], [albums], [artists]) is backed by a real feed for
/// every method — see the "Browse feeds" table in the plugin README for
/// exactly what backs each one and how confident that backing is. None of the
/// three is a stub that always returns empty:
///
/// * [tracks] reads SoundCloud's own `/charts` — trending or top, chosen by
///   [SwayveSortOrder], regioned by the `region` setting.
/// * [artists] is *derived* from that same chart response: the uploaders of
///   trending/top tracks, deduplicated by user id. This is not a claim that
///   SoundCloud publishes a "trending artists" feed of its own — it doesn't,
///   anonymously — it's an honest, documented derivation from data that is
///   genuinely real, reusing the chart request rather than making a second
///   one.
/// * [albums] reads `/playlists/discovery`, filtered to `is_album: true`.
///   This endpoint's exact shape has not been exercised against live
///   traffic, so parsing degrades to fewer items rather than throwing when a
///   guess about its envelope is wrong — see `SoundCloudClient
///   .playlistDiscovery`.
///
/// **Lookup** ([album], [artist]) fetches the entity directly and always
/// works regardless of what the listing methods can offer. Both return
/// `null` — never an exception — for an id this provider did not mint, an id
/// of the wrong kind, or an id SoundCloud no longer resolves.
///
/// Listing results carry **no track list** (`SwayveAlbum.tracks` is always
/// empty from [albums]) — exactly per the SDK's own documented contract for
/// that field: populated by a lookup, not a listing. Hydrating every result
/// on a shelf would mean one playlist fetch per cover, which is bandwidth
/// nobody asked for to draw a grid.
final class SoundCloudCatalogProvider implements SwayveCatalogProvider {
  /// Creates a provider over [client].
  SoundCloudCatalogProvider({
    required SoundCloudClient client,
    required SwayveSettingsView settings,
    this.timeouts = SoundCloudTimeouts.manifest,
  })  : _client = client,
        _settings = settings;

  final SoundCloudClient _client;
  final SwayveSettingsView _settings;

  /// The deadlines this provider works to.
  final SoundCloudTimeouts timeouts;

  /// The `region` setting, read fresh on every chart request rather than
  /// cached at construction — the same discipline the YouTube Music plugin
  /// applies to its own `region` setting, for the same reason: a user who
  /// changes it should not keep getting the old chart until the app restarts.
  String get region =>
      _settings.value<String>(kRegionSettingId) ?? kDefaultRegion;

  @override
  Future<SwayvePage<SwayveTrack>> tracks(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'tracks',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final SoundCloudPage page = await _client.chartTracks(
            kind: chartKindFor(request.sort),
            region: region,
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
  Future<SwayvePage<SwayveArtist>> artists(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'artists',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final SoundCloudPage page = await _client.chartTracks(
            kind: chartKindFor(request.sort),
            region: region,
            cursor: request.cursor,
            cancel: cancel,
          );
          final List<SwayveArtist> artists = <SwayveArtist>[];
          final Set<int> seen = <int>{};
          for (final Object? item in page.items) {
            final Map<String, Object?> track = unwrapChartItem(item);
            final SwayveArtist? artist = parseArtist(mapAt(track, ['user']));
            if (artist == null) continue;
            final int? numeric = SoundCloudIds.numericValue(artist.id);
            if (numeric != null && seen.add(numeric)) artists.add(artist);
          }
          return SwayvePage<SwayveArtist>(items: artists, cursor: page.nextHref);
        },
      );

  @override
  Future<SwayvePage<SwayveAlbum>> albums(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'albums',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final SoundCloudPage page = await _client.playlistDiscovery(
            cursor: request.cursor,
            cancel: cancel,
          );
          final List<SwayveAlbum> albums = <SwayveAlbum>[
            for (final Object? item in page.items)
              if (parsePlaylistEnvelope(mapOf(item)) case final envelope?)
                if (albumFromEnvelope(envelope, const <SwayveTrack>[])
                    case final album?)
                  album,
          ];
          return SwayvePage<SwayveAlbum>(items: albums, cursor: page.nextHref);
        },
      );

  @override
  Future<SwayveAlbum?> album(
    SwayveMediaId id, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'album',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          if (!SoundCloudIds.isKind(id, SoundCloudIdKind.playlist)) {
            return null;
          }
          final int numeric = SoundCloudIds.numericValue(id)!;
          final Map<String, Object?>? json =
              await _client.playlist(numeric, cancel: cancel);
          if (json == null) return null;
          final ParsedPlaylistEnvelope? envelope = parsePlaylistEnvelope(json);
          if (envelope == null || !envelope.isAlbum) return null;
          cancel?.throwIfCancelled();
          final List<SwayveTrack> tracks =
              await _client.hydratePlaylistTracks(envelope, cancel: cancel);
          return albumFromEnvelope(envelope, tracks);
        },
      );

  @override
  Future<SwayveArtist?> artist(
    SwayveMediaId id, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'artist',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          if (!SoundCloudIds.isKind(id, SoundCloudIdKind.user)) return null;
          final int numeric = SoundCloudIds.numericValue(id)!;
          final Map<String, Object?>? json =
              await _client.user(numeric, cancel: cancel);
          if (json == null) return null;
          return parseArtist(json);
        },
      );
}
