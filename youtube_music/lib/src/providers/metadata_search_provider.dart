import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../innertube_client.dart';
import '../json_path.dart';
import '../parsing/feed_parser.dart';

/// YouTube Music's answer to `SwayveMetadataSearchProvider`. Capability:
/// `metadata_search`.
///
/// This is the capability that lets a host identify a track a structured
/// database like MusicBrainz has nothing for — an extended mix, a bootleg,
/// an unreleased song — because YouTube's upload catalogue is very often
/// the only place that recording exists at all. It answers a different
/// question from `YouTubeMusicSearchProvider`: that one takes a person's
/// typed phrase and returns shelves of results to browse; this one takes
/// what the host already believes about a track — its title, its artist,
/// how long it runs — and returns ranked candidates for *that specific
/// song*, which is the shape a metadata resolver needs rather than the
/// shape a search screen does.
///
/// [searchTrack] searches both the licensed catalogue and the video
/// uploads unconditionally, unlike [YouTubeMusicSearchProvider] which
/// gates the second shelf behind the `include_videos` setting. A metadata
/// lookup exists specifically to find the songs that only live in the
/// second shelf, so honouring a setting written for the browse screen
/// would defeat the reason this capability was added.
final class YouTubeMusicMetadataSearchProvider
    implements SwayveMetadataSearchProvider {
  /// Creates a provider over [client].
  YouTubeMusicMetadataSearchProvider({
    required InnerTubeClient client,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  }) : _client = client;

  final InnerTubeClient _client;

  /// The deadlines this provider works to.
  final YouTubeMusicTimeouts timeouts;

  @override
  Future<List<SwayveMetadataCandidate>> searchTrack(
    SwayveMetadataQuery query, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'searchTrack',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final String text = _queryText(query);
          if (text.isEmpty) return const <SwayveMetadataCandidate>[];

          final List<ParsedFeed> shelves = await Future.wait(
            <Future<ParsedFeed>>[
              _shelf(
                text,
                params: YouTubeMusicSearchFilters.songs,
                cancel: cancel,
              ),
              _shelf(
                text,
                params: YouTubeMusicSearchFilters.videos,
                cancel: cancel,
              ),
            ],
          );

          // The same recording is frequently in both shelves under the same
          // video id — de-duplicated the same way the search provider does,
          // so the resolver is not handed the same candidate twice with two
          // different confidence scores computed against it.
          final Set<String> seen = <String>{};
          final List<SwayveMetadataCandidate> candidates =
              <SwayveMetadataCandidate>[];
          for (final ParsedFeed shelf in shelves) {
            for (final SwayveTrack track in shelf.items.tracks) {
              if (!seen.add(track.id.value)) continue;
              candidates.add(_candidateFrom(track));
            }
          }
          return candidates;
        },
      );

  @override
  Future<SwayveMetadataCandidate?> resolveUrl(
    Uri url, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'resolveUrl',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final String? videoId = _videoIdFrom(url);
          if (videoId == null) return null;

          final Map<String, Object?> response = await _client.player(
            videoId,
            cancel: cancel,
          );
          final String status = stringAt(
                response,
                const <Object>['playabilityStatus', 'status'],
              ) ??
              '';
          // Not every refusal here is worth reporting as a failure — a
          // private, deleted or region-blocked video is simply not
          // resolvable, the same "not found" [YouTubeStreamRefusal] draws
          // for playback. Reported as no candidate rather than an
          // exception, matching this method's own contract: `null` means
          // "recognised the URL, found nothing there."
          if (status != 'OK') return null;

          final String? title = stringAt(
            response,
            const <Object>['videoDetails', 'title'],
          );
          if (title == null || title.trim().isEmpty) return null;

          final String? author = stringAt(
            response,
            const <Object>['videoDetails', 'author'],
          );
          // Sent as a string, the same as every other numeric field this
          // plugin reads off a player response — see
          // `parsing/stream_parser.dart`'s `_statedDuration`.
          final int? seconds = int.tryParse(
            stringAt(
                  response,
                  const <Object>['videoDetails', 'lengthSeconds'],
                ) ??
                '',
          );

          return SwayveMetadataCandidate(
            providerItemId: videoId,
            title: title,
            artists: author == null || author.trim().isEmpty
                ? const <String>[]
                : <String>[author],
            duration: seconds == null || seconds <= 0
                ? null
                : Duration(seconds: seconds),
            sourceUrl: Uri.parse('$kMusicOrigin/watch?v=$videoId'),
          );
        },
      );

  Future<ParsedFeed> _shelf(
    String text, {
    required String params,
    SwayveCancellationToken? cancel,
  }) async =>
      parseFeed(
        await _client.search(text, params: params, cancel: cancel),
        what: 'metadata search',
      );

  /// The host's title and primary artist, joined the way a person would
  /// type them into the search box — the same construction
  /// `YouTubeMusicSearchProvider` receives from a person, just assembled
  /// here instead of typed there.
  static String _queryText(SwayveMetadataQuery query) {
    final String title = (query.title ?? '').trim();
    final String artist =
        query.artists.isEmpty ? '' : query.artists.first.trim();
    return <String>[
      if (title.isNotEmpty) title,
      if (artist.isNotEmpty) artist,
    ].join(' ');
  }

  static SwayveMetadataCandidate _candidateFrom(SwayveTrack track) =>
      SwayveMetadataCandidate(
        providerItemId: track.id.value,
        title: track.title,
        artists: <String>[for (final ref in track.artists) ref.name],
        album: track.album?.title,
        year: track.year,
        duration: track.duration,
        artwork: track.artwork?.uri,
        sourceUrl: track.externalUrl,
      );

  /// The video id [url] names, or `null` when it does not name one of ours.
  ///
  /// Two shapes are recognised: `youtu.be/<id>` and any `youtube.com`
  /// subdomain's `watch?v=<id>` — the two forms a person actually pastes.
  /// [YouTubeMusicIds.classify] is what decides whether the extracted
  /// string is really shaped like a video id, so a URL such as
  /// `youtube.com/watch?v=not_an_id` is refused rather than handed to the
  /// player endpoint as though it were one.
  static String? _videoIdFrom(Uri url) {
    final String host = url.host.toLowerCase();
    String? candidate;
    if (host == 'youtu.be') {
      candidate = url.pathSegments.isEmpty ? null : url.pathSegments.first;
    } else if (host == 'youtube.com' ||
        host == 'www.youtube.com' ||
        host == 'music.youtube.com') {
      candidate = url.queryParameters['v'];
    }
    if (candidate == null) return null;
    return YouTubeMusicIds.classify(candidate) == YouTubeMusicIdKind.track
        ? candidate
        : null;
  }
}
