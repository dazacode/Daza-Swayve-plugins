import 'dart:convert';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../innertube_client.dart';
import '../parsing/detail_parser.dart';
import '../parsing/feed_parser.dart';
import '../parsing/mood_parser.dart';

/// YouTube Music's answer to `SwayvePlaylistProvider`. Capability:
/// `playlist_read`.
///
/// ## Two kinds of playlist, one surface
///
/// A signed-in listener has playlists they saved and made. Everybody,
/// including a signed-out visitor, has YouTube Music's own editorial ones —
/// the "'80s Rock" and "Chill Hits" shelves the home page is built out of.
/// Both are playlists, both open with the same browse, and a provider that
/// served only the first would show an empty library to everyone who has not
/// pasted a cookie.
///
/// Which one a call means is chosen by [SwayveBrowseRequest.sort], mirroring
/// exactly what `catalog_provider.dart` already does with the same field —
/// see [feedFor]. Only the personal source ever throws
/// `SwayvePluginAuthRequiredException`; asking for the curated one signed out
/// is an ordinary request that works.
///
/// ## Ids
///
/// [playlistTracks] accepts every shape one of these ids arrives in — a
/// `browseEndpoint`'s already-`VL`-prefixed id, a watch endpoint's bare
/// `PL…`/`OLAK5uy_…`/`RDCLAK5uy_…`, or whichever of the two a `SwayveMediaId`
/// happens to hold — because they all reach this method and InnerTube answers
/// 400 for `VLVL…`. Normalization is `YouTubeMusicIds.playlistBrowseId`,
/// which strips before it adds and is therefore idempotent.
///
/// **This is a read-only surface, deliberately.** `playlistRead` has no
/// `_write` sibling in the SDK, and nothing here creates, edits or reorders
/// anything on somebody's account.
final class YouTubeMusicPlaylistProvider implements SwayvePlaylistProvider {
  /// Creates a provider over [client] and [credentials].
  YouTubeMusicPlaylistProvider({
    required InnerTubeClient client,
    required SwayveCredentialStore credentials,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  })  : _client = client,
        _credentials = credentials;

  final InnerTubeClient _client;
  final SwayveCredentialStore _credentials;

  /// The deadlines this provider works to.
  final YouTubeMusicTimeouts timeouts;

  /// The browse this provider draws playlists from for [sort].
  ///
  /// * `relevance` and no sort at all mean "the obvious list": the
  ///   listener's own playlists when there is a session to read them from,
  ///   and YouTube Music's curated home shelves when there is not. That is
  ///   the one case where being signed in changes the answer, and it changes
  ///   it towards the more personal one.
  /// * `recent` and `popular` are the curated feeds `catalog_provider.dart`
  ///   already maps them to, read for their playlists rather than their
  ///   albums.
  /// * `alphabetical` is the mood and genre directory — the closest thing
  ///   YouTube Music has to "browse the names" — and the one that costs a
  ///   second request. See [_curatedFromChips].
  static String feedFor(SwayveSortOrder? sort, {required bool signedIn}) =>
      switch (sort) {
        SwayveSortOrder.recent => YouTubeMusicFeeds.newReleases,
        SwayveSortOrder.popular => YouTubeMusicFeeds.charts,
        SwayveSortOrder.alphabetical => YouTubeMusicFeeds.moodsAndGenres,
        SwayveSortOrder.relevance ||
        null =>
          signedIn ? YouTubeMusicFeeds.likedPlaylists : YouTubeMusicFeeds.home,
      };

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
          final String? cookie = await _credentials.readSecret(
            kSessionCookieSettingId,
          );
          final bool signedIn = cookie != null && cookie.trim().isNotEmpty;
          final String feed = feedFor(request.sort, signedIn: signedIn);

          if (feed == YouTubeMusicFeeds.moodsAndGenres) {
            return _curatedFromChips(request, cancel);
          }

          final bool personal = feed == YouTubeMusicFeeds.likedPlaylists;
          final Map<String, Object?> body = await _client.browse(
            feed,
            continuation: request.cursor,
            sessionCookie: personal ? cookie : null,
            pageId: personal
                ? await _credentials.readSecret(kPageIdSettingId)
                : null,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();

          // Only the personal source. A stored cookie InnerTube no longer
          // honours answers 200 with YouTube Music's own "Looking for what
          // you've liked?" placeholder — confirmed against the live endpoint
          // — which `parseFeed` alone reads as a genuinely empty library. The
          // curated feeds never carry it and must never be failed over it.
          if (personal && looksSignedOut(body)) {
            throw const SwayvePluginAuthRequiredException(
              'YouTube Music: sign in to see your playlists.',
            );
          }

          final ParsedFeed feed0 = parseFeed(body, what: 'playlists');
          return SwayvePage<SwayvePlaylist>(
            items: List<SwayvePlaylist>.unmodifiable(feed0.items.playlists),
            cursor: feed0.cursor,
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
          if (!YouTubeMusicIds.isKind(id, YouTubeMusicIdKind.playlist)) {
            return const SwayvePage<SwayveTrack>();
          }
          final Map<String, Object?> body = await _client.browse(
            YouTubeMusicIds.playlistBrowseId(id.value),
            continuation: request.cursor,
            // Sent when there is one, and harmless when there is not. A
            // curated or community playlist browses perfectly well
            // anonymously — measured: a 100-track editorial playlist and a
            // 20-track community one both answered 200 with no session at all
            // — but a listener's own private playlist does not.
            sessionCookie: await _credentials.readSecret(
              kSessionCookieSettingId,
            ),
            pageId: await _credentials.readSecret(kPageIdSettingId),
            cancel: cancel,
          );
          cancel?.throwIfCancelled();
          final ParsedFeed feed = parseFeed(body, what: 'playlistTracks');
          return SwayvePage<SwayveTrack>(
            items: List<SwayveTrack>.unmodifiable(feed.items.tracks),
            cursor: feed.cursor,
          );
        },
      );

  /// The playlist itself, header and all.
  ///
  /// Not part of `SwayvePlaylistProvider` — the SDK's v1 surface pages tracks
  /// and never asks for the collection they belong to — but the same browse
  /// already carries the header, so answering it costs nothing and a host
  /// that grows the surface will not need a new request path. Exactly the
  /// reasoning behind `YouTubeMusicCatalogProvider.albumTracks`.
  ///
  /// `null` for an id of the wrong kind or one the service no longer
  /// resolves; never an exception for either.
  Future<SwayvePlaylist?> playlist(
    SwayveMediaId id, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'playlist',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          if (!YouTubeMusicIds.isKind(id, YouTubeMusicIdKind.playlist)) {
            return null;
          }
          final Map<String, Object?> body = await _client.browse(
            YouTubeMusicIds.playlistBrowseId(id.value),
            sessionCookie: await _credentials.readSecret(
              kSessionCookieSettingId,
            ),
            pageId: await _credentials.readSecret(kPageIdSettingId),
            cancel: cancel,
          );
          cancel?.throwIfCancelled();
          final ParsedFeed? feed = tryParseFeed(body);
          return parsePlaylistDetail(
            body,
            id.value,
            tracks: feed?.items.tracks ?? const <SwayveTrack>[],
          );
        },
      );

  /// The mood and genre directory, opened one category at a time.
  ///
  /// The directory itself holds no playlists — see `parsing/mood_parser.dart`
  /// for what it holds instead and why a chip must not be minted as one — so
  /// this browses chips and then browses a bounded number of them for the
  /// playlists behind them. Whatever is left over goes into the cursor, so
  /// "load more" carries on down the list rather than starting it again.
  ///
  /// A category that fails is stepped over rather than thrown from: it is one
  /// shelf of thirty-eight, and the playlists already gathered are a better
  /// answer than an exception.
  Future<SwayvePage<SwayvePlaylist>> _curatedFromChips(
    SwayveBrowseRequest request,
    SwayveCancellationToken? cancel,
  ) async {
    final _ChipQueue queue = _ChipQueue.decode(request.cursor) ??
        _ChipQueue(
          params: <String>[
            for (final MoodChip chip in parseMoodChips(
              await _client.browse(
                YouTubeMusicFeeds.moodsAndGenres,
                cancel: cancel,
              ),
            ))
              chip.params,
          ],
        );
    cancel?.throwIfCancelled();

    final List<String> remaining = <String>[...queue.params];
    final List<SwayvePlaylist> playlists = <SwayvePlaylist>[];
    final Set<String> seen = <String>{};

    for (int opened = 0;
        opened < _maxCategoriesPerPage &&
            remaining.isNotEmpty &&
            playlists.length < request.limit;
        opened++) {
      cancel?.throwIfCancelled();
      final String params = remaining.removeAt(0);
      try {
        final ParsedFeed? feed = tryParseFeed(
          await _client.browse(
            YouTubeMusicFeeds.moodsAndGenresCategory,
            params: params,
            cancel: cancel,
          ),
        );
        for (final SwayvePlaylist playlist
            in feed?.items.playlists ?? const <SwayvePlaylist>[]) {
          if (seen.add(playlist.id.value)) playlists.add(playlist);
        }
      } on SwayvePluginException {
        continue;
      }
    }

    return SwayvePage<SwayvePlaylist>(
      items: List<SwayvePlaylist>.unmodifiable(playlists),
      cursor: remaining.isEmpty ? null : _ChipQueue(params: remaining).encode(),
    );
  }

  /// How many mood or genre categories one page will open.
  ///
  /// Two, set by the deadline rather than by taste, and for exactly the
  /// reason `YouTubeMusicCatalogProvider` bounds its own shelf-opening at the
  /// same figure: these requests run one after another inside a single
  /// operation budget, and each may take a whole request budget.
  static const int _maxCategoriesPerPage = 2;
}

/// Which mood and genre categories a curated listing has still to open.
///
/// The same trick `catalog_provider.dart` uses for its own multi-request
/// listing: the SDK's cursor is one opaque string the host hands back
/// untouched, and [_marker] is what makes a cursor this class wrote tellable
/// apart from an InnerTube continuation token that arrived the same way.
final class _ChipQueue {
  const _ChipQueue({required this.params});

  /// The `params` blobs not yet opened, in the directory's own order.
  final List<String> params;

  static const String _marker = 'ytm.mg1.';

  /// Reads a cursor this class wrote, or `null` for anything else.
  ///
  /// `null` rather than an exception for a malformed one: a cursor is a value
  /// that crossed a process boundary and came back, and the worst a corrupted
  /// one should be able to do is start the listing over.
  static _ChipQueue? decode(String? cursor) {
    if (cursor == null || !cursor.startsWith(_marker)) return null;
    try {
      final Object? decoded = jsonDecode(
        utf8.decode(base64Url.decode(cursor.substring(_marker.length))),
      );
      if (decoded is! Map<String, Object?>) return null;
      final Object? queued = decoded['p'];
      return _ChipQueue(
        params: <String>[
          if (queued is List<Object?>)
            for (final Object? entry in queued)
              if (entry is String) entry,
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// This position as one opaque string.
  String encode() =>
      _marker +
      base64Url.encode(
        utf8.encode(jsonEncode(<String, Object?>{'p': params})),
      );
}
