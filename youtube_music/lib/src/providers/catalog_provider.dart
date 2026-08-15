import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../innertube_client.dart';
import '../parsing/detail_parser.dart';
import '../parsing/feed_parser.dart';
import '../parsing/item_parser.dart';

/// YouTube Music's answer to `SwayveCatalogProvider`. Capability: `catalog`.
///
/// **Listing** ([albums], [artists], [tracks]) browses one of YouTube Music's
/// own feeds and partitions what comes back. `SwayveSortOrder` picks the feed:
/// `recent` is new releases, `popular` is the charts, and everything else is
/// the home feed — an order with no corresponding feed falls back rather than
/// failing, because the SDK says sort is a hint.
///
/// **Lookup** ([album], [artist]) browses the entity directly. Both return
/// `null` — never an exception — for an id this provider did not mint, an id
/// of the wrong kind, or an id the service no longer resolves. "Not found" and
/// "could not look" are different facts and the host shows them differently.
///
/// Paging is by cursor throughout: the token is InnerTube's own continuation
/// token, passed back to the host as an opaque string and handed straight back
/// to the service on the next call.
final class YouTubeMusicCatalogProvider implements SwayveCatalogProvider {
  /// Creates a provider over [client].
  YouTubeMusicCatalogProvider({
    required InnerTubeClient client,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  }) : _client = client;

  final InnerTubeClient _client;

  /// The deadlines this provider works to.
  final YouTubeMusicTimeouts timeouts;

  /// The feed that best serves [sort].
  static String feedFor(SwayveSortOrder? sort) => switch (sort) {
        SwayveSortOrder.recent => YouTubeMusicFeeds.newReleases,
        SwayveSortOrder.popular => YouTubeMusicFeeds.charts,
        SwayveSortOrder.relevance ||
        SwayveSortOrder.alphabetical ||
        null =>
          YouTubeMusicFeeds.home,
      };

  @override
  Future<SwayvePage<SwayveAlbum>> albums(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      _page(
        'albums',
        request,
        cancel,
        (ItemCollector items) => items.albums,
      );

  @override
  Future<SwayvePage<SwayveArtist>> artists(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      _page(
        'artists',
        request,
        cancel,
        (ItemCollector items) => items.artists,
      );

  @override
  Future<SwayvePage<SwayveTrack>> tracks(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      _page(
        'tracks',
        request,
        cancel,
        (ItemCollector items) => items.tracks,
      );

  Future<SwayvePage<T>> _page<T>(
    String operation,
    SwayveBrowseRequest request,
    SwayveCancellationToken? cancel,
    List<T> Function(ItemCollector items) select,
  ) =>
      runGuarded(
        operation,
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final Map<String, Object?> body = await _client.browse(
            feedFor(request.sort),
            continuation: request.cursor,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();
          final ParsedFeed feed = parseFeed(body, what: operation);
          final int limit = request.limit < 0 ? 0 : request.limit;
          final List<T> items = select(feed.items);
          return SwayvePage<T>(
            items: List<T>.unmodifiable(items.take(limit)),
            // A cursor is only useful if the caller can act on it. Reporting
            // one when the feed is exhausted would make `hasMore` lie.
            cursor: feed.cursor,
          );
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
          if (!YouTubeMusicIds.isKind(id, YouTubeMusicIdKind.album)) {
            return null;
          }
          final Map<String, Object?> body = await _client.browse(
            id.value,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();
          final ParsedFeed? feed = tryParseFeed(body);
          return parseAlbumDetail(
            body,
            id.value,
            tracks: feed?.items.tracks ?? const <SwayveTrack>[],
          );
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
          if (!YouTubeMusicIds.isKind(id, YouTubeMusicIdKind.artist)) {
            return null;
          }
          final Map<String, Object?> body = await _client.browse(
            id.value,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();
          return parseArtistDetail(body, id.value);
        },
      );

  /// The tracks of one album, in album order.
  ///
  /// Not part of `SwayveCatalogProvider` — the SDK has no album-tracks method
  /// in v1 — but the browse response already carries them, so exposing them is
  /// free and a host that grows the surface will not need a new request path.
  Future<List<SwayveTrack>> albumTracks(
    SwayveMediaId id, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'albumTracks',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          if (!YouTubeMusicIds.isKind(id, YouTubeMusicIdKind.album)) {
            return const <SwayveTrack>[];
          }
          final Map<String, Object?> body = await _client.browse(
            id.value,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();
          return tryParseFeed(body)?.items.tracks ?? const <SwayveTrack>[];
        },
      );
}
