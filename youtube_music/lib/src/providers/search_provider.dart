import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../innertube_client.dart';
import '../parsing/feed_parser.dart';
import '../parsing/item_parser.dart';

/// YouTube Music's answer to `SwayveSearchProvider`. Capability: `search`.
///
/// Three contract obligations shape it.
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
/// **A search for songs searches the videos too.** YouTube Music's catalogue
/// and YouTube's uploads are two different indexes behind one search box, and
/// only the first has albums, sleeves and licences behind it. The second is
/// where the unreleased track, the remix, the demo and the live rip live — for
/// a great deal of music it is the *only* place it exists — so asking only the
/// catalogue means a song somebody can hear on YouTube right now returns "no
/// matches" here. Both shelves are searched and both are returned, each track
/// published as [SwayveTrackKind.video] so a host can tell them apart. Turned
/// off by the `include_videos` setting, for somebody who wants the catalogue
/// alone.
///
/// **`limit` is a ceiling per kind, not a total** — that is what the SDK says
/// it means, and returning twenty tracks *and* twenty albums for `limit: 20`
/// is correct.
final class YouTubeMusicSearchProvider implements SwayveSearchProvider {
  /// Creates a provider over [client].
  YouTubeMusicSearchProvider({
    required InnerTubeClient client,
    required SwayveSettingsView settings,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  })  : _client = client,
        _settings = settings;

  final InnerTubeClient _client;
  final SwayveSettingsView _settings;

  /// The deadlines this provider works to.
  final YouTubeMusicTimeouts timeouts;

  /// The filter token that scopes a search to [kind].
  static String? filterFor(SwayveSearchKind kind) => switch (kind) {
        SwayveSearchKind.track => YouTubeMusicSearchFilters.songs,
        SwayveSearchKind.album => YouTubeMusicSearchFilters.albums,
        SwayveSearchKind.artist => YouTubeMusicSearchFilters.artists,
        SwayveSearchKind.playlist => YouTubeMusicSearchFilters.playlists,
      };

  /// Whether video uploads are searched alongside the catalogue.
  ///
  /// Read fresh on every search rather than cached, for the same reason
  /// `InnerTubeClient.region` is: the user can change it while the plugin is
  /// running.
  bool get includeVideos =>
      _settings.value<bool>(kIncludeVideosSettingId) ?? kDefaultIncludeVideos;

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

          // The songs-and-videos pair, which is the case worth spending a
          // second request on. Only when tracks are the single kind asked for:
          // a mixed search is already returning every shelf the service felt
          // like sending, and doubling that to add videos would be paying for
          // albums and artists twice over.
          final bool paired = kinds.length == 1 &&
              kinds.single == SwayveSearchKind.track &&
              includeVideos;

          final _Cursors cursors = _Cursors.decode(query.cursor);

          final _Shelf songs = await _shelf(
            text,
            params: kinds.length == 1 ? filterFor(kinds.single) : null,
            cursor: cursors.songs,
            exhausted: cursors.isContinuation && cursors.songs == null,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();

          final _Shelf videos = paired
              ? await _shelf(
                  text,
                  params: YouTubeMusicSearchFilters.videos,
                  cursor: cursors.videos,
                  exhausted: cursors.isContinuation && cursors.videos == null,
                  cancel: cancel,
                )
              : _Shelf.none;

          // The catalogue first, then the uploads. Not a ranking of quality —
          // an upload is often the better recording — but of confidence: a
          // catalogue row is a known release with a known title, and a host
          // drawing one list wants those at the top. A host drawing two
          // sections reads the stamp instead and ignores this order entirely.
          final List<SwayveTrack> catalogue =
              songs.feed?.items.tracks ?? const <SwayveTrack>[];
          final List<SwayveTrack> tracks = <SwayveTrack>[
            ..._stamped(catalogue, SwayveTrackKind.song),
            ..._stamped(
              videos.feed?.items.tracks,
              SwayveTrackKind.video,
              seen: <String>{
                for (final SwayveTrack track in catalogue) track.id.value,
              },
            ),
          ];

          final ItemCollector? items = songs.feed?.items;
          // Filtered to the kinds that were asked for, and not cut to [limit].
          //
          // The same reasoning as `YouTubeMusicCatalogProvider._page`, which
          // has it at length: one cursor bookmarks the whole response, so
          // returning fewer results than were parsed while reporting that
          // cursor means the difference is never requested by anything again.
          // Filtering by kind is safe because it throws away a shelf the host
          // said it did not want; truncating throws away part of a shelf it
          // did.
          //
          // It matters twice over here. This list is two shelves — the
          // catalogue and the uploads — so a cut at twenty would decide on the
          // host's behalf that the videos are the half worth losing, which for
          // a song that exists only as an upload is the whole answer.
          List<T> wanted<T>(SwayveSearchKind kind, List<T>? found) =>
              kinds.contains(kind) && found != null
                  ? List<T>.unmodifiable(found)
                  : const <Never>[];

          return SwayveSearchResult(
            tracks: wanted(SwayveSearchKind.track, tracks),
            albums: wanted(SwayveSearchKind.album, items?.albums),
            artists: wanted(SwayveSearchKind.artist, items?.artists),
            playlists: wanted(SwayveSearchKind.playlist, items?.playlists),
            cursor: _Cursors(
              songs: songs.feed?.cursor,
              videos: videos.feed?.cursor,
            ).encode(),
            // `partial` is the honest signal that something in the payload was
            // unreadable and the user is looking at fewer results than the
            // service returned. Truncation to `limit` is not partial: there is
            // a cursor for the rest.
            partial: songs.skipped || videos.skipped,
          );
        },
      );

  /// One filtered search, or nothing when this shelf has already ended.
  Future<_Shelf> _shelf(
    String text, {
    required String? params,
    required String? cursor,
    required bool exhausted,
    SwayveCancellationToken? cancel,
  }) async {
    // A shelf whose cursor came back null last time is a shelf with no more
    // pages. Asking it again would restart it from the top and hand the host
    // the first twenty results a second time, as though they were new.
    if (exhausted) return _Shelf.none;
    return _Shelf(
      parseFeed(
        await _client.search(
          text,
          params: params,
          continuation: cursor,
          cancel: cancel,
        ),
        what: 'search',
      ),
    );
  }

  /// [tracks] with their origin recorded, skipping anything already in [seen].
  ///
  /// The de-duplication matters more than it looks: the same recording is
  /// frequently in both indexes, and the two shelves describe it with the same
  /// video id. Without this a paired search shows the popular songs twice, once
  /// with a sleeve and once with a video frame.
  Iterable<SwayveTrack> _stamped(
    List<SwayveTrack>? tracks,
    SwayveTrackKind kind, {
    Set<String> seen = const <String>{},
  }) sync* {
    for (final SwayveTrack track in tracks ?? const <SwayveTrack>[]) {
      if (seen.contains(track.id.value)) continue;
      yield track.copyWith(kind: kind);
    }
  }
}

/// One shelf's answer.
final class _Shelf {
  const _Shelf(this.feed);

  /// The shelf that was not asked for, or has no pages left.
  static const _Shelf none = _Shelf(null);

  final ParsedFeed? feed;

  bool get skipped => feed?.items.skippedItems ?? false;
}

/// Where each of the two shelves has read to.
///
/// A search that spans two shelves needs two continuation tokens and the SDK
/// has one slot for a cursor — correctly, because a cursor is the *provider's*
/// bookmark and the host is told not to look inside it. So both are packed into
/// one opaque string here and unpacked here, and nothing outside this file ever
/// learns there are two.
final class _Cursors {
  const _Cursors({this.songs, this.videos, this.isContinuation = true});

  /// The pair encoded in [raw], or an empty pair for a first page.
  ///
  /// A cursor from before this encoding existed is a bare token, and is read as
  /// the songs shelf's — which is what it was.
  factory _Cursors.decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const _Cursors(isContinuation: false);
    }
    if (!raw.startsWith(_prefix)) return _Cursors(songs: raw);
    final List<String> parts = raw.substring(_prefix.length).split('|');
    String? at(int index) =>
        index < parts.length && parts[index].isNotEmpty ? parts[index] : null;
    return _Cursors(songs: at(0), videos: at(1));
  }

  static const String _prefix = 'ytm2|';

  final String? songs;
  final String? videos;

  /// Whether this pair came off a previous page rather than starting one.
  final bool isContinuation;

  /// The single opaque string the host holds, or `null` when both shelves are
  /// finished — which is what makes `hasMore` false.
  String? encode() {
    if (songs == null && videos == null) return null;
    return '$_prefix${songs ?? ''}|${videos ?? ''}';
  }
}
