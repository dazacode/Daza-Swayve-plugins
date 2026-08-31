import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../innertube_client.dart';
import '../parsing/feed_parser.dart';
import '../parsing/item_parser.dart';
import '../parsing/watch_parser.dart';

/// YouTube Music's answer to `SwayveRadioProvider`. Capability: `radio`.
///
/// ## Two different questions, two different endpoints
///
/// [startRadio] and [radioTracks] ask `next` — the endpoint behind "what
/// plays after this" — for an endless station. [related] does **not**. The
/// obvious implementation of "more like this" is a second `next` call and a
/// slice off the queue, and it is the wrong answer: the station is ordered to
/// be *listened to*, so its first rows are the safest possible neighbours of
/// the seed rather than the most related things the service knows about.
///
/// The `next` response already names somewhere better. Its four tabs are `Up
/// next`, `Lyrics`, `Comments` and `Related`, and the last one carries a
/// browse id of the form `MPTR…` — a page of six shelves, of which two are
/// tracks ("You might also like", "Other performances") and the rest are
/// playlists and artists. That page is what a person sees when they tap
/// Related, and it is what this returns.
///
/// ## What is deliberately not here
///
/// Nothing in this file writes. There is no `like`, no `subscribe`, no
/// playlist edit and no `playbackTracking` ping — not because they are hard,
/// but because this plugin is a read-only integration by decision. A radio
/// improves as YouTube learns what somebody listened to, and this plugin
/// still does not tell it.
final class YouTubeMusicRadioProvider implements SwayveRadioProvider {
  /// Creates a provider over [client].
  YouTubeMusicRadioProvider({
    required InnerTubeClient client,
    required SwayveSettingsView settings,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  })  : _client = client,
        _settings = settings;

  final InnerTubeClient _client;
  final SwayveSettingsView _settings;

  /// The deadlines this provider works to.
  final YouTubeMusicTimeouts timeouts;

  /// The first page of the station [startRadio] most recently minted.
  ///
  /// Starting a station and asking for its first page are two calls in the
  /// SDK and one request at the service: `next` answers with the handle *and*
  /// fifty rows, and there is nowhere on [SwayveRadio] to put them. Holding
  /// the one page here is what stops [radioTracks] re-asking for something
  /// this provider was handed thirty milliseconds ago.
  ///
  /// One station deep, and dropped as soon as it is served. A radio is a
  /// session-lifetime thing — the SDK says so explicitly — so a cache that
  /// grew with use would be a leak wearing a cache's clothes.
  _FirstPage? _firstPage;

  /// Whether video results are filtered out of a station.
  ///
  /// Read from the existing `include_videos` setting rather than from a new
  /// one of its own. The setting already means "search the upload half of
  /// YouTube as well as the licensed catalogue", and a listener who turned it
  /// off is asking not to be handed music videos; a station is the same
  /// question asked by a different surface.
  ///
  /// It matters more here than anywhere else in this plugin. Measured against
  /// the live endpoint, a station seeded from a music video comes back as
  /// fifty `MUSIC_VIDEO_TYPE_OMV` rows and **not one** audio track — and
  /// sending `isAudioOnly: true` in the request body changes nothing at all.
  /// So with this on, such a station legitimately serves empty pages, which
  /// [radioTracks] reports the way the SDK asks: empty, but with a cursor,
  /// which means "ask again" rather than "the station ran dry".
  bool get _audioOnly => !(_settings.value<bool>(kIncludeVideosSettingId) ??
      kDefaultIncludeVideos);

  @override
  Future<SwayveRadio?> startRadio(
    SwayveMediaId seed, {
    SwayveMediaId? context,
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'startRadio',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final WatchSeed? request = _seedFor(seed, context);
          // `null`, not an exception: an id this provider never minted and a
          // recording it cannot build a station around are both "not found",
          // which is what the SDK asks for here.
          if (request == null) return null;

          final Map<String, Object?> body = await _client.next(
            request.videoId ?? '',
            playlistId: request.playlistId,
            params: request.params,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();

          final ParsedWatchQueue? queue = tryParseWatchQueue(
            body,
            seedVideoId: request.videoId,
            audioOnly: _audioOnly,
          );
          if (queue == null) return null;

          // A station that came back with nothing in it is not a station.
          // Checked before the audio-only filter is allowed to be blamed for
          // it: an unfiltered parse of the same body is what says whether the
          // service had anything at all.
          final ParsedWatchQueue unfiltered = _audioOnly
              ? tryParseWatchQueue(body, seedVideoId: request.videoId)!
              : queue;
          if (unfiltered.tracks.isEmpty && unfiltered.cursor == null) {
            return null;
          }

          // The station id the service itself named, when it named one —
          // ours is a synthesis and its is a fact. Same for the `automix`
          // endpoint a short panel ends with: forwarded verbatim rather than
          // rebuilt.
          final WatchSeed next = queue.automix ??
              WatchSeed(
                videoId: request.videoId,
                playlistId: queue.playlistId ?? request.playlistId,
                params: request.params,
              );

          final SwayveRadio radio = SwayveRadio(
            id: YouTubeMusicIds.mediaId(next.playlistId),
            title: queue.title,
            seed: seed,
            artwork: queue.tracks.isEmpty ? null : queue.tracks.first.artwork,
            extra: <String, Object?>{
              ...next.toJson(),
              'isInfinite': queue.isInfinite,
            },
          );
          _firstPage = _FirstPage(
            radioId: radio.id.value,
            audioOnly: _audioOnly,
            tracks: queue.tracks,
            cursor: queue.cursor,
          );
          return radio;
        },
      );

  @override
  Future<SwayvePage<SwayveTrack>> radioTracks(
    SwayveRadio radio,
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'radioTracks',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final String? cursor = request.cursor;

          if (cursor == null) {
            final _FirstPage? held = _firstPage;
            if (held != null &&
                held.radioId == radio.id.value &&
                held.audioOnly == _audioOnly) {
              // Served once. Holding it past the call that asked for it would
              // make a second pass over the same station serve a page that is
              // by then minutes stale.
              _firstPage = null;
              return SwayvePage<SwayveTrack>(
                items: held.tracks,
                cursor: held.cursor,
              );
            }
          }

          final WatchSeed? seed = WatchSeed.fromJson(radio.extra);
          if (cursor == null && seed == null) {
            // Nothing to ask with: a radio this provider did not mint, or one
            // that survived a restart with its extras stripped. An empty page
            // with no cursor is how the SDK says a station has ended, which
            // is the honest answer — this one cannot be resumed.
            return const SwayvePage<SwayveTrack>();
          }

          final Map<String, Object?> body = cursor != null
              ? await _client.nextContinuation(cursor, cancel: cancel)
              : await _client.next(
                  seed!.videoId ?? '',
                  playlistId: seed.playlistId,
                  params: seed.params,
                  cancel: cancel,
                );
          cancel?.throwIfCancelled();

          final ParsedWatchQueue queue = parseWatchQueue(
            body,
            what: 'radioTracks',
            seedVideoId: cursor == null ? seed?.videoId : null,
            audioOnly: _audioOnly,
          );
          return SwayvePage<SwayveTrack>(
            items: queue.tracks,
            // Reported exactly as the service gave it. An empty page with a
            // cursor means "ask again" and an empty page without one means the
            // station is over — which is the distinction the audio-only filter
            // makes load-bearing, since it can empty a page the service filled.
            cursor: queue.cursor,
          );
        },
      );

  @override
  Future<List<SwayveTrack>> related(
    SwayveMediaId id, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'related',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          if (!YouTubeMusicIds.isKind(id, YouTubeMusicIdKind.track)) {
            return const <SwayveTrack>[];
          }
          final Map<String, Object?> watch = await _client.next(
            id.value,
            playlistId: YouTubeMusicRadio.forVideo(id.value),
            params: YouTubeMusicRadio.seedParams,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();

          final String? browseId = relatedBrowseIdOf(watch);
          // An empty list is a real answer here — "I looked and there is
          // nothing near it" — and the SDK reserves exceptions for something
          // else entirely.
          if (browseId == null) return const <SwayveTrack>[];

          final ParsedFeed? feed = tryParseFeed(
            await _client.browse(browseId, cancel: cancel),
          );
          if (feed == null) return const <SwayveTrack>[];

          // Every shelf's tracks, in payload order, and nothing else off the
          // page. The collector partitions by endpoint kind, so the playlist
          // and artist shelves sort themselves out without this having to
          // read a shelf title — which is localized and would make related
          // tracks work in English and nowhere else.
          final ItemCollector items = feed.items;
          final List<SwayveTrack> tracks = <SwayveTrack>[];
          final Set<String> seen = <String>{id.value};
          for (final SwayveTrack track in items.tracks) {
            if (_audioOnly && track.kind != SwayveTrackKind.song) continue;
            if (seen.add(track.id.value)) tracks.add(track);
          }
          return List<SwayveTrack>.unmodifiable(tracks);
        },
      );

  /// The `next` request that starts a station seeded by [seed], or `null`
  /// when this provider cannot build one.
  ///
  /// [context] is what the person was listening *in*. It is used for one
  /// thing only: when it already names a station — a `RD…` id the service
  /// minted earlier — it is forwarded verbatim, because a station id YouTube
  /// handed over beats one synthesised from a video id. Otherwise the seed
  /// decides, since steering a track's radio with the album it came from
  /// returns that album's neighbours rather than the song's.
  WatchSeed? _seedFor(SwayveMediaId seed, SwayveMediaId? context) {
    if (context != null &&
        YouTubeMusicIds.kindOf(context) == YouTubeMusicIdKind.playlist &&
        YouTubeMusicRadio.isStation(
          YouTubeMusicIds.barePlaylistId(context.value),
        )) {
      return WatchSeed(
        videoId: YouTubeMusicIds.isKind(seed, YouTubeMusicIdKind.track)
            ? seed.value
            : null,
        playlistId: YouTubeMusicIds.barePlaylistId(context.value),
        params: YouTubeMusicRadio.seedParams,
      );
    }

    switch (YouTubeMusicIds.kindOf(seed)) {
      case YouTubeMusicIdKind.track:
        return WatchSeed(
          videoId: seed.value,
          playlistId: YouTubeMusicRadio.forVideo(seed.value),
          params: YouTubeMusicRadio.seedParams,
        );
      case YouTubeMusicIdKind.album:
      case YouTubeMusicIdKind.playlist:
        final String bare = YouTubeMusicIds.barePlaylistId(seed.value);
        return WatchSeed(
          playlistId: YouTubeMusicRadio.isStation(bare)
              ? bare
              : YouTubeMusicRadio.forCollection(bare),
          params: YouTubeMusicRadio.seedParams,
        );
      case YouTubeMusicIdKind.artist:
      // An artist channel is not a radio seed on this endpoint: `next` wants
      // a video or a playlist, and there is no `RD…` prefix that turns a `UC`
      // channel id into one. Rather than send a request that will not answer,
      // this says it cannot — which is what `null` means here.
      case null:
        return null;
    }
  }
}

/// The page [YouTubeMusicRadioProvider.startRadio] already paid for.
final class _FirstPage {
  const _FirstPage({
    required this.radioId,
    required this.audioOnly,
    required this.tracks,
    required this.cursor,
  });

  /// Which station this belongs to.
  final String radioId;

  /// The filter that was in force when it was parsed. A page parsed with
  /// videos included is the wrong answer to a request made after the setting
  /// was turned off, so it is refetched rather than reused.
  final bool audioOnly;

  final List<SwayveTrack> tracks;
  final String? cursor;
}
