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

  /// One page of a feed.
  ///
  /// ## Why [SwayveBrowseRequest.limit] does not cut this list
  ///
  /// The obvious reading of `limit` is a knife: parse the response, take that
  /// many, hand back the cursor. That reading loses music, and it is what put
  /// songs missing from albums.
  ///
  /// One InnerTube response is many shelves, and the single continuation token
  /// it carries points past **all** of them. So taking fifty of eighty and
  /// reporting that cursor meant the next page resumed after the eightieth: the
  /// thirty in between were not slow to arrive, they were gone, and nothing
  /// would ever ask for them again. A host assembling albums out of the songs
  /// it has been handed then drew a twelve-track record with the four that
  /// survived the cut, with nothing on screen to say the rest existed.
  ///
  /// There is no way to resume mid-shelf — InnerTube's cursor is the only
  /// bookmark it offers and it has one granularity — so the choice is between
  /// dropping items and returning more than were asked for. This returns more.
  /// A caller that genuinely cannot hold them can still take what it wants off
  /// the front, which is a decision it can make without losing anything;
  /// discarding them here is a decision nothing can undo.
  ///
  /// `limit` therefore reaches the service as it always did — it is the shelf
  /// size the feed is asked for — and is not applied a second time to the
  /// answer.
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
          return SwayvePage<T>(
            items: List<T>.unmodifiable(select(feed.items)),
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
          return parseAlbumDetail(
            body,
            id.value,
            tracks: await _listing(body, id.value, cancel: cancel),
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
          return _listing(body, id.value, cancel: cancel);
        },
      );

  /// Every track a browse response lists, following its continuations.
  ///
  /// A release's songs are the one listing that has to arrive complete. A feed
  /// cut short is a shelf somebody can scroll for more; a track list cut short
  /// is a record that is missing songs, with nothing on screen to say so — and
  /// InnerTube pages an album's rows like anything else once it is long enough,
  /// so a single response is not the whole record for box sets, deluxe editions
  /// or any playlist worth the name.
  ///
  /// Bounded by [_maxListingPages] rather than run to exhaustion: this is the
  /// listing of one release, so the bound is generous enough that reaching it
  /// means something is wrong rather than that somebody owns a long record.
  ///
  /// A continuation that fails is swallowed. What has been gathered so far is a
  /// truer answer than an exception — the first page is the one that matters,
  /// and losing the whole album because its fourth page timed out would trade a
  /// small gap for a total one.
  Future<List<SwayveTrack>> _listing(
    Map<String, Object?> body,
    String browseId, {
    SwayveCancellationToken? cancel,
  }) async {
    final ParsedFeed? first = tryParseFeed(body);
    if (first == null) return const <SwayveTrack>[];

    final List<SwayveTrack> tracks = <SwayveTrack>[...first.items.tracks];
    final Set<String> seen = <String>{
      for (final SwayveTrack track in tracks) track.id.value,
    };
    String? cursor = first.cursor;

    for (int page = 0; page < _maxListingPages && cursor != null; page++) {
      cancel?.throwIfCancelled();
      final ParsedFeed next;
      try {
        next = parseFeed(
          await _client.browse(browseId, continuation: cursor, cancel: cancel),
          what: 'albumTracks',
        );
      } on SwayvePluginException {
        break;
      }
      // A continuation that returns nothing new is a continuation that is not
      // advancing, and following it again would be an infinite request loop
      // against somebody else's service.
      bool grew = false;
      for (final SwayveTrack track in next.items.tracks) {
        if (seen.add(track.id.value)) {
          tracks.add(track);
          grew = true;
        }
      }
      if (!grew) break;
      cursor = next.cursor;
    }

    return tracks;
  }

  /// How many continuations a track listing will follow.
  ///
  /// Ten pages is several hundred rows — longer than any album and longer than
  /// most playlists — so hitting it means the listing is not terminating rather
  /// than that it is genuinely this long.
  static const int _maxListingPages = 10;
}
