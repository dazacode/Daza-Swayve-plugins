import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../json_path.dart';
import '../parsing/playlist_parser.dart';
import '../parsing/track_parser.dart';
import '../parsing/user_parser.dart';
import '../soundcloud_client.dart';

/// SoundCloud's answer to `SwayveSearchProvider`. Capability: `search`.
///
/// One endpoint per requested kind — `/search/tracks`, `/search/albums`,
/// `/search/playlists`, `/search/users` — so a single-kind search pays for
/// one shelf, not four; the same reasoning the YouTube Music plugin applies
/// to its own per-kind filter tokens. `limit` is a ceiling per kind, applied
/// exactly once by the upstream request itself and never truncated again
/// afterwards: one `next_href` bookmarks a whole shelf, so cutting the parsed
/// result short would make that bookmark point past songs nothing would ever
/// ask for again.
///
/// `album`-kind and `playlist`-kind results both come from SoundCloud
/// `playlists` objects — `is_album` decides which of
/// `SwayveSearchResult.albums`/`.playlists` a given result lands in, filtered
/// locally rather than trusted to the endpoint's own partitioning, so the
/// split is correct even if a query returns a stray result of the other
/// flavour.
final class SoundCloudSearchProvider implements SwayveSearchProvider {
  /// Creates a provider over [client].
  SoundCloudSearchProvider({
    required SoundCloudClient client,
    this.timeouts = SoundCloudTimeouts.manifest,
  }) : _client = client;

  final SoundCloudClient _client;

  /// The deadlines this provider works to.
  final SoundCloudTimeouts timeouts;

  static String _pathFor(SwayveSearchKind kind) => switch (kind) {
        SwayveSearchKind.track => 'tracks',
        SwayveSearchKind.album => 'albums',
        SwayveSearchKind.artist => 'users',
        SwayveSearchKind.playlist => 'playlists',
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
          final String text = query.text.trim();
          if (text.isEmpty) return SwayveSearchResult.empty;
          final Set<SwayveSearchKind> kinds =
              query.kinds.isEmpty ? SwayveSearchQuery.allKinds : query.kinds;
          final _Cursors cursors = _Cursors.decode(query.cursor);

          Future<SoundCloudPage> shelf(
            SwayveSearchKind kind,
            String? shelfCursor,
          ) {
            if (!kinds.contains(kind)) {
              return Future<SoundCloudPage>.value(SoundCloudPage.empty);
            }
            // A shelf whose cursor came back null last time has no more
            // pages; asking again would restart it from the top and hand the
            // host the first results a second time as though they were new.
            if (cursors.isContinuation && shelfCursor == null) {
              return Future<SoundCloudPage>.value(SoundCloudPage.empty);
            }
            return _client.search(
              _pathFor(kind),
              text,
              limit: query.limit,
              cursor: shelfCursor,
              cancel: cancel,
            );
          }

          final SoundCloudPage trackPage =
              await shelf(SwayveSearchKind.track, cursors.track);
          cancel?.throwIfCancelled();
          final SoundCloudPage albumPage =
              await shelf(SwayveSearchKind.album, cursors.album);
          cancel?.throwIfCancelled();
          final SoundCloudPage artistPage =
              await shelf(SwayveSearchKind.artist, cursors.artist);
          cancel?.throwIfCancelled();
          final SoundCloudPage playlistPage =
              await shelf(SwayveSearchKind.playlist, cursors.playlist);

          final List<SwayveAlbum> albums = <SwayveAlbum>[
            for (final Object? item in albumPage.items)
              if (parsePlaylistEnvelope(mapOf(item)) case final envelope?)
                if (albumFromEnvelope(envelope, const <SwayveTrack>[])
                    case final album?)
                  album,
          ];
          final List<SwayvePlaylist> playlists = <SwayvePlaylist>[
            for (final Object? item in playlistPage.items)
              if (parsePlaylistEnvelope(mapOf(item)) case final envelope?)
                if (!envelope.isAlbum) playlistFromEnvelope(envelope),
          ];

          return SwayveSearchResult(
            tracks: parseTrackList(trackPage.items),
            albums: albums,
            artists: parseArtistList(artistPage.items),
            playlists: playlists,
            cursor: _Cursors(
              track: trackPage.nextHref,
              album: albumPage.nextHref,
              artist: artistPage.nextHref,
              playlist: playlistPage.nextHref,
            ).encode(),
          );
        },
      );
}

/// Where each of up to four search shelves has read to.
///
/// A search that spans several kinds needs one continuation token per shelf,
/// and the SDK has one cursor slot — correctly, since a cursor is the
/// *provider's* bookmark and the host is told not to look inside it. All four
/// are packed into one opaque string here and unpacked here, generalizing
/// `YouTubeMusicSearchProvider._Cursors`' two-shelf scheme to SoundCloud's
/// four search kinds.
final class _Cursors {
  const _Cursors({
    this.track,
    this.album,
    this.artist,
    this.playlist,
    this.isContinuation = true,
  });

  /// The four-way tuple encoded in [raw], or an empty one for a first page.
  factory _Cursors.decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return const _Cursors(isContinuation: false);
    }
    if (!raw.startsWith(_prefix)) {
      malformedResponse('an unrecognised search cursor was supplied: $raw');
    }
    final List<String> parts = raw.substring(_prefix.length).split('|');
    String? at(int index) =>
        index < parts.length && parts[index].isNotEmpty ? parts[index] : null;
    return _Cursors(
      track: at(0),
      album: at(1),
      artist: at(2),
      playlist: at(3),
    );
  }

  static const String _prefix = 'sc2|';

  final String? track;
  final String? album;
  final String? artist;
  final String? playlist;

  /// Whether this tuple came off a previous page rather than starting one.
  final bool isContinuation;

  /// The single opaque string the host holds, or `null` when every shelf is
  /// finished — which is what makes `hasMore` false.
  String? encode() {
    if (track == null && album == null && artist == null && playlist == null) {
      return null;
    }
    return '$_prefix${track ?? ''}|${album ?? ''}|${artist ?? ''}|${playlist ?? ''}';
  }
}
