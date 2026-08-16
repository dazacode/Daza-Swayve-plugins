import 'dart:convert';

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

  /// Songs from the feed that best serves [SwayveBrowseRequest.sort].
  ///
  /// ## Why this is not `_page(items.tracks)` like its two neighbours
  ///
  /// Because the feeds do not carry songs. Every other listing here works
  /// because the shelf it wants is on the page it asked for; this one asked for
  /// the same page and got nothing, permanently, and the reason is a fact about
  /// YouTube Music rather than a defect in the parsing.
  ///
  /// A signed-out browse of `FEmusic_charts` returns about a hundred rows and
  /// **not one of them carries a video id**: the shelves are "Top albums",
  /// "Top artists", "Video charts" and "Genres", and every entry is a record,
  /// a channel or a playlist. `FEmusic_home` is the same shape — twenty cards,
  /// no songs. So [tracks] returned an empty page, always, and there was
  /// nothing to notice: an empty page is a legitimate answer and the host drew
  /// it as one. The visible consequence was that opening the library showed a
  /// source with nothing in it, and the only thing that ever put a song in
  /// there was somebody typing a search — which is a search cache wearing a
  /// library's clothes.
  ///
  /// The songs are one hop away. Those chart playlists are exactly the "top
  /// songs" listing the feed no longer inlines, and browsing one returns
  /// twenty rows that each carry a video id, an artist and a running time. So
  /// when a feed yields no songs of its own, this follows the playlists it
  /// does yield, which is the same answer the feed used to give directly.
  ///
  /// A feed that *does* carry songs is served straight through, unchanged. The
  /// hop is a fallback rather than the design: nothing here assumes the
  /// catalogue will keep its current shape, and the day a song shelf comes back
  /// this stops making the extra request on its own.
  @override
  Future<SwayvePage<SwayveTrack>> tracks(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'tracks',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () => _tracks(request, cancel),
      );

  Future<SwayvePage<SwayveTrack>> _tracks(
    SwayveBrowseRequest request,
    SwayveCancellationToken? cancel,
  ) async {
    // A cursor this method minted means the last page was already being served
    // out of playlists, so the feed is not asked again — it would hand back the
    // same shelves and the same playlists a second time.
    final _TrackQueue? resuming = _TrackQueue.decode(request.cursor);
    if (resuming != null) return _tracksFromPlaylists(resuming, request, cancel);

    final Map<String, Object?> body = await _client.browse(
      feedFor(request.sort),
      continuation: request.cursor,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();
    final ParsedFeed feed = parseFeed(body, what: 'tracks');

    if (feed.items.tracks.isNotEmpty) {
      return SwayvePage<SwayveTrack>(
        items: List<SwayveTrack>.unmodifiable(feed.items.tracks),
        cursor: feed.cursor,
      );
    }

    return _tracksFromPlaylists(
      _TrackQueue(
        playlists: <String>[
          for (final SwayvePlaylist playlist in feed.items.playlists)
            playlist.id.value,
        ],
        feed: feed.cursor,
      ),
      request,
      cancel,
    );
  }

  /// Serves songs by opening the queued playlists in turn.
  ///
  /// Stops at [SwayveBrowseRequest.limit] songs or [_maxPlaylistsPerPage]
  /// playlists, whichever comes first — the second bound is what keeps one call
  /// to this from turning into ten requests when a chart playlist happens to be
  /// short. Whatever is left over goes back in the cursor, so the next page
  /// carries on from the same shelf rather than starting the feed again.
  ///
  /// A playlist that fails is stepped over rather than thrown from. It is one
  /// shelf of many, the songs already gathered are a better answer than an
  /// exception, and the alternative is one unavailable chart emptying a library
  /// page that had twenty perfectly good songs on it.
  Future<SwayvePage<SwayveTrack>> _tracksFromPlaylists(
    _TrackQueue from,
    SwayveBrowseRequest request,
    SwayveCancellationToken? cancel,
  ) async {
    final List<String> queue = <String>[...from.playlists];
    final List<SwayveTrack> tracks = <SwayveTrack>[];
    final Set<String> seen = <String>{};
    String? feed = from.feed;

    for (int opened = 0;
        opened < _maxPlaylistsPerPage && tracks.length < request.limit;) {
      if (queue.isEmpty) {
        // Out of playlists, but the feed had more shelves. Taking the next of
        // them is what makes "load more" keep working past the first response
        // rather than stopping at whatever the first page happened to name.
        if (feed == null) break;
        final ParsedFeed? next = await _nextFeedPage(feed, request, cancel);
        if (next == null) {
          feed = null;
          break;
        }
        queue.addAll(<String>[
          for (final SwayvePlaylist playlist in next.items.playlists)
            playlist.id.value,
        ]);
        // Songs on a later shelf are taken directly; the hop exists because
        // there were none, not because playlists are preferred.
        for (final SwayveTrack track in next.items.tracks) {
          if (seen.add(track.id.value)) tracks.add(track);
        }
        feed = next.cursor;
        if (queue.isEmpty && feed == null) break;
        continue;
      }

      opened++;
      for (final SwayveTrack track in await _playlistTracks(
        queue.removeAt(0),
        cancel,
      )) {
        if (seen.add(track.id.value)) tracks.add(track);
      }
    }

    final bool exhausted = queue.isEmpty && feed == null;
    return SwayvePage<SwayveTrack>(
      items: List<SwayveTrack>.unmodifiable(tracks),
      // Null at the end, so `hasMore` does not promise a page that would come
      // back empty for ever.
      cursor: exhausted
          ? null
          : _TrackQueue(playlists: queue, feed: feed).encode(),
    );
  }

  /// One playlist's songs, or none when it could not be read.
  Future<List<SwayveTrack>> _playlistTracks(
    String playlistId,
    SwayveCancellationToken? cancel,
  ) async {
    cancel?.throwIfCancelled();
    try {
      final ParsedFeed? feed = tryParseFeed(
        await _client.browse(
          YouTubeMusicIds.playlistBrowseId(playlistId),
          cancel: cancel,
        ),
      );
      return feed?.items.tracks ?? const <SwayveTrack>[];
    } on SwayvePluginException {
      return const <SwayveTrack>[];
    }
  }

  /// The next page of shelves, or `null` when the feed would not give one.
  Future<ParsedFeed?> _nextFeedPage(
    String cursor,
    SwayveBrowseRequest request,
    SwayveCancellationToken? cancel,
  ) async {
    cancel?.throwIfCancelled();
    try {
      return parseFeed(
        await _client.browse(
          feedFor(request.sort),
          continuation: cursor,
          cancel: cancel,
        ),
        what: 'tracks',
      );
    } on SwayvePluginException {
      return null;
    }
  }

  /// How many playlists one page of [tracks] will open.
  ///
  /// Two, and the number is set by the deadline rather than by taste. These
  /// requests are made one after another — the loop stops as soon as the page
  /// is full, which is what keeps this from opening shelves nobody asked for —
  /// so they share one operation budget between them, and each of them may
  /// take a whole request budget. Two playlists behind one feed is three
  /// requests against a budget of two request-lengths' slack, which is the
  /// most this can spend and still fail the way it is supposed to: late, on a
  /// network that has genuinely stopped answering, rather than routinely on a
  /// slow one.
  ///
  /// Two chart playlists is forty songs, which is a page.
  static const int _maxPlaylistsPerPage = 2;

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

/// Where a song listing that is being served out of playlists has got to.
///
/// The SDK's cursor is one opaque string and the host hands it back untouched,
/// which is exactly what this needs: two facts have to survive to the next page
/// — the playlists that have not been opened yet, and where the feed that named
/// them had got to — and there is one field to put them in.
///
/// [_marker] is what makes the two kinds of cursor tellable apart. A feed that
/// carries songs of its own hands back InnerTube's own continuation token
/// unchanged, and that token comes straight back here on the next call; without
/// a marker this would have to guess whether a given string was one of its own,
/// and guessing wrong means either decoding a live token as JSON or browsing a
/// playlist queue as a continuation.
final class _TrackQueue {
  const _TrackQueue({required this.playlists, required this.feed});

  /// Playlist ids not yet opened, in the order the feed named them.
  final List<String> playlists;

  /// The feed's own continuation, for when [playlists] runs out.
  final String? feed;

  static const String _marker = 'ytm.q1.';

  /// Reads a cursor this class wrote, or `null` for anything else.
  ///
  /// Null rather than an exception for a malformed one, and deliberately: a
  /// cursor is a value that crossed a process boundary and came back, and the
  /// worst a corrupted one should be able to do is start the listing over.
  static _TrackQueue? decode(String? cursor) {
    if (cursor == null || !cursor.startsWith(_marker)) return null;
    try {
      final Object? decoded = jsonDecode(
        utf8.decode(base64Url.decode(cursor.substring(_marker.length))),
      );
      if (decoded is! Map<String, Object?>) return null;
      final Object? queued = decoded['q'];
      final Object? feed = decoded['f'];
      return _TrackQueue(
        playlists: <String>[
          if (queued is List<Object?>)
            for (final Object? entry in queued)
              if (entry is String) entry,
        ],
        feed: feed is String ? feed : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// This position as one opaque string.
  String encode() =>
      _marker +
      base64Url.encode(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'q': playlists,
            if (feed != null) 'f': feed,
          }),
        ),
      );
}
