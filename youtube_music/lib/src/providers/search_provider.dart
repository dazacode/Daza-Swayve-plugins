import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../innertube_client.dart';
import '../parsing/feed_parser.dart';

/// YouTube Music's answer to `SwayveSearchProvider`. Capability: `search`.
///
/// Two contract obligations shape it.
///
/// **`kinds` is honoured on the wire when it can be.** When the host asks for
/// exactly one kind, the request carries YouTube Music's own filter token for
/// that kind, so the service returns one shelf instead of five and the user
/// pays for one shelf of bandwidth. When several kinds are wanted, one
/// unfiltered search is cheaper than several filtered ones, and the results
/// are partitioned locally. Either way the returned result is filtered again
/// before it is handed back, so a shelf the service volunteered can never leak
/// into a kind the host did not ask for.
///
/// **`limit` is a ceiling per kind, not a total** — that is what the SDK says
/// it means, and returning twenty tracks *and* twenty albums for `limit: 20`
/// is correct.
final class YouTubeMusicSearchProvider implements SwayveSearchProvider {
  /// Creates a provider over [client].
  YouTubeMusicSearchProvider({
    required InnerTubeClient client,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  }) : _client = client;

  final InnerTubeClient _client;

  /// The deadlines this provider works to.
  final YouTubeMusicTimeouts timeouts;

  /// The filter token that scopes a search to [kind].
  static String? filterFor(SwayveSearchKind kind) => switch (kind) {
        SwayveSearchKind.track => YouTubeMusicSearchFilters.songs,
        SwayveSearchKind.album => YouTubeMusicSearchFilters.albums,
        SwayveSearchKind.artist => YouTubeMusicSearchFilters.artists,
        SwayveSearchKind.playlist => YouTubeMusicSearchFilters.playlists,
      };

  @override
  Future<SwayveSearchResult> search(
    SwayveSearchQuery query, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'search',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final Set<SwayveSearchKind> kinds =
              query.kinds.isEmpty ? SwayveSearchQuery.allKinds : query.kinds;
          final String text = query.text.trim();
          if (text.isEmpty) return SwayveSearchResult.empty;

          final Map<String, Object?> body = await _client.search(
            text,
            params: kinds.length == 1 ? filterFor(kinds.single) : null,
            continuation: query.cursor,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();

          final ParsedFeed feed = parseFeed(body, what: 'search');
          final int limit = query.limit < 0 ? 0 : query.limit;
          List<T> wanted<T>(SwayveSearchKind kind, List<T> items) =>
              kinds.contains(kind)
                  ? List<T>.unmodifiable(items.take(limit))
                  : const <Never>[];

          return SwayveSearchResult(
            tracks: wanted(SwayveSearchKind.track, feed.items.tracks),
            albums: wanted(SwayveSearchKind.album, feed.items.albums),
            artists: wanted(SwayveSearchKind.artist, feed.items.artists),
            playlists: wanted(SwayveSearchKind.playlist, feed.items.playlists),
            cursor: feed.cursor,
            // `partial` is the honest signal that something in the payload was
            // unreadable and the user is looking at fewer results than the
            // service returned. Truncation to `limit` is not partial: there is
            // a cursor for the rest.
            partial: feed.items.skippedItems,
          );
        },
      );
}
