/// The parser for InnerTube's `next` endpoint — the "what plays after this"
/// response a radio is served out of.
///
/// It is deliberately not `feed_parser.dart` with another shelf key bolted
/// on. A watch queue is a different document from a browse feed in three ways
/// that all bite:
///
/// * **its rows are `playlistPanelVideoRenderer`s**, which look nothing like
///   the `musicResponsiveListItemRenderer` rows every other listing is made
///   of — the id is at the top level, the length is in `lengthText`, and the
///   credit is in `longBylineText`;
/// * **that byline is video-shaped, not album-shaped.** A search row reads
///   `Artist • Album • 3:32`. A radio row reads
///   `Rick Astley • 1.8B views • 19M likes`, so anything that took the second
///   bullet-separated segment as an album would file every station under a
///   record called "1.8B views". Artists are read from the runs that actually
///   carry an artist `browseEndpoint`, and **no album is invented**;
/// * **it pages under `nextRadioContinuationData`**, not the
///   `nextContinuationData` every browse uses.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../artwork.dart';
import '../ids.dart';
import '../json_path.dart';
import 'item_parser.dart';

/// One page of a watch queue.
final class ParsedWatchQueue {
  /// Creates a parsed queue.
  const ParsedWatchQueue({
    required this.tracks,
    this.playlistId,
    this.title,
    this.cursor,
    this.isInfinite = false,
    this.automix,
  });

  /// The rows of this page, in payload order, after filtering.
  final List<SwayveTrack> tracks;

  /// The station's own playlist id, as the service stated it.
  final String? playlistId;

  /// What the service calls this station, when its header says.
  final String? title;

  /// The continuation token for the next page, or `null` at the end.
  final String? cursor;

  /// Whether the service says this station goes on for ever.
  ///
  /// Read from `playlistPanelRenderer.isInfinite`, which is served directly —
  /// not inferred from the presence of a continuation, which would be a guess
  /// about a fact the payload already states.
  final bool isInfinite;

  /// The endpoint an `automixPlaylistVideoRenderer` row named, when the page
  /// carried one.
  ///
  /// A short panel sometimes ends with a placeholder row that is not a track
  /// at all: it names the playlist and `params` that *extend* the queue.
  /// Forwarded verbatim rather than re-derived — a station id the service
  /// handed over is a better seed than one synthesised out of a video id.
  final WatchSeed? automix;
}

/// A `videoId` / `playlistId` / `params` triple, as InnerTube states it.
///
/// The unit a radio request is made of. Kept as one value so that a seed the
/// service named can be forwarded exactly as given.
final class WatchSeed {
  /// Creates a seed.
  const WatchSeed({this.videoId, required this.playlistId, this.params});

  /// The recording the station starts from, when there is one.
  final String? videoId;

  /// The station's playlist id.
  final String playlistId;

  /// The opaque blob that distinguishes "start a station" from "open this".
  final String? params;

  /// This seed as JSON, for `SwayveRadio.extra`.
  Map<String, Object?> toJson() => <String, Object?>{
        if (videoId != null) 'videoId': videoId,
        'playlistId': playlistId,
        if (params != null) 'params': params,
      };

  /// Reads a seed back out of `SwayveRadio.extra`, or `null`.
  static WatchSeed? fromJson(Map<String, Object?> json) {
    final Object? playlistId = json['playlistId'];
    if (playlistId is! String || playlistId.isEmpty) return null;
    final Object? videoId = json['videoId'];
    final Object? params = json['params'];
    return WatchSeed(
      videoId: videoId is String && videoId.isNotEmpty ? videoId : null,
      playlistId: playlistId,
      params: params is String && params.isNotEmpty ? params : null,
    );
  }
}

/// Whether [musicVideoType] describes an audio recording rather than
/// something somebody filmed.
///
/// `MUSIC_VIDEO_TYPE_ATV` is an "art track" — the audio-only rendition
/// YouTube Music generates for a licensed release. `_OMV` is an official
/// music video and `_UGC` a user upload; both are watched rather than
/// listened to.
///
/// This is the **only** thing that separates the two, and it has to be
/// applied here rather than asked for. Measured against the live endpoint:
/// sending `isAudioOnly: true` in the `next` request body changes nothing —
/// the same fifty `_OMV` rows come back with it and without it.
bool isAudioOnlyType(String? musicVideoType) =>
    musicVideoType == null || musicVideoType == 'MUSIC_VIDEO_TYPE_ATV';

/// The `SwayveTrackKind` a `musicVideoType` describes.
///
/// Unknown values fall to [SwayveTrackKind.song], matching what
/// `item_parser.dart` already does for the same field and for the same
/// reason: a video filed as a song is a row in the wrong list, while a song
/// filed as a video disappears out of the list somebody was looking at.
SwayveTrackKind trackKindForMusicVideoType(String? musicVideoType) =>
    switch (musicVideoType) {
      null || 'MUSIC_VIDEO_TYPE_ATV' => SwayveTrackKind.song,
      _ => SwayveTrackKind.video,
    };

/// Parses a `next` response, or a continuation of one, into one page.
///
/// [seedVideoId] is dropped from the result when it appears: **the seed comes
/// back as element zero of its own station**, which is correct of the service
/// — the panel is the queue, and the queue starts with what is playing — and
/// wrong for a caller asking "what comes next". Measured, not assumed.
///
/// [audioOnly] drops every row whose `musicVideoType` says it is a video. Off
/// by default: a station seeded from a music video is *all* videos, and a
/// provider that filtered by default would hand back an empty page for the
/// most ordinary request there is.
///
/// [what] names the request in a failure message, used only when the body
/// carries no watch queue at all.
ParsedWatchQueue parseWatchQueue(
  Map<String, Object?> body, {
  required String what,
  String? seedVideoId,
  bool audioOnly = false,
}) {
  final ParsedWatchQueue? parsed = tryParseWatchQueue(
    body,
    seedVideoId: seedVideoId,
    audioOnly: audioOnly,
  );
  if (parsed == null) {
    malformedResponse('the $what response carried no watch queue.');
  }
  return parsed;
}

/// Parses a `next` response, or `null` when the body holds no watch queue.
ParsedWatchQueue? tryParseWatchQueue(
  Map<String, Object?> body, {
  String? seedVideoId,
  bool audioOnly = false,
}) {
  final Map<String, Object?>? panel = _panelOf(body);
  if (panel == null) return null;

  final List<SwayveTrack> tracks = <SwayveTrack>[];
  final Set<String> seen = <String>{if (seedVideoId != null) seedVideoId};
  WatchSeed? automix;

  for (final Object? entry in listAt(panel, const <Object>['contents'])) {
    final Map<String, Object?> wrapper = mapOf(entry);

    final Object? mix = wrapper['automixPlaylistVideoRenderer'];
    if (mix != null) {
      automix ??= _seedOf(
        dig(mix, const <Object>['navigationEndpoint', 'watchPlaylistEndpoint']),
      );
      continue;
    }

    final Object? row = wrapper['playlistPanelVideoRenderer'];
    if (row == null) continue;
    final Map<String, Object?> renderer = mapOf(row);

    final String? videoId = stringAt(renderer, const <Object>['videoId']) ??
        stringAt(renderer, const <Object>[
          'navigationEndpoint',
          'watchEndpoint',
          'videoId',
        ]);
    if (videoId == null || videoId.isEmpty) continue;

    final String? musicVideoType = stringAt(renderer, const <Object>[
      'navigationEndpoint',
      'watchEndpoint',
      'watchEndpointMusicSupportedConfigs',
      'watchEndpointMusicConfig',
      'musicVideoType',
    ]);
    if (audioOnly && !isAudioOnlyType(musicVideoType)) continue;

    // The seed is element zero of its own station; dedupe covers that and any
    // repeat a long continuation happens to serve twice.
    if (!seen.add(videoId)) continue;

    final String? title = runsTextAt(renderer, const <Object>['title', 'runs']);
    if (title == null || title.trim().isEmpty) continue;

    tracks.add(_trackOf(renderer, videoId, title.trim(), musicVideoType));
  }

  return ParsedWatchQueue(
    tracks: List<SwayveTrack>.unmodifiable(tracks),
    playlistId: stringAt(panel, const <Object>['playlistId']),
    title: _stationTitle(body),
    cursor: watchContinuationOf(panel),
    isInfinite: dig(panel, const <Object>['isInfinite']) == true,
    automix: automix,
  );
}

/// The `playlistPanelRenderer` of [body], in either shape it arrives in.
///
/// A first page nests it five renderers deep under the watch-next tab
/// structure; a continuation answers with a flat
/// `continuationContents.playlistPanelContinuation` carrying the same fields
/// under a different name. Both confirmed against the live endpoint.
Map<String, Object?>? _panelOf(Map<String, Object?> body) {
  final Map<String, Object?> continuation = mapAt(body, const <Object>[
    'continuationContents',
    'playlistPanelContinuation',
  ]);
  if (continuation.isNotEmpty) return continuation;

  for (final Object? tab in _watchTabs(body)) {
    final Map<String, Object?> panel = mapAt(tab, const <Object>[
      'tabRenderer',
      'content',
      'musicQueueRenderer',
      'content',
      'playlistPanelRenderer',
    ]);
    if (panel.isNotEmpty) return panel;
  }
  return null;
}

/// The tabs of a watch-next response: `Up next`, `Lyrics`, `Comments`,
/// `Related`.
List<Object?> _watchTabs(Map<String, Object?> body) => listAt(
      body,
      const <Object>[
        'contents',
        'singleColumnMusicWatchNextResultsRenderer',
        'tabbedRenderer',
        'watchNextTabbedResultsRenderer',
        'tabs',
      ],
    );

/// The browse id of the "Related" tab, or `null` when this response has none.
///
/// **Found by page type, never by tab title.** The titles are localized —
/// "Related" is "Relacionado" for a Spanish user — so keying off them would
/// make related-tracks work in English and return nothing everywhere else.
/// `MUSIC_PAGE_TYPE_TRACK_RELATED` is not localized, and the `MPTR` id shape
/// is the fallback for a response that omits the config.
String? relatedBrowseIdOf(Map<String, Object?> body) {
  String? byShape;
  for (final Object? tab in _watchTabs(body)) {
    final Object? endpoint = dig(tab, const <Object>[
      'tabRenderer',
      'endpoint',
      'browseEndpoint',
    ]);
    final String? browseId = stringAt(endpoint, const <Object>['browseId']);
    if (browseId == null || browseId.isEmpty) continue;
    final String? pageType = stringAt(endpoint, const <Object>[
      'browseEndpointContextSupportedConfigs',
      'browseEndpointContextMusicConfig',
      'pageType',
    ]);
    if (pageType == 'MUSIC_PAGE_TYPE_TRACK_RELATED') return browseId;
    if (browseId.startsWith('MPTR')) byShape ??= browseId;
  }
  return byShape;
}

/// The continuation token of a watch panel, or `null`.
///
/// `nextRadioContinuationData` rather than the `nextContinuationData` a browse
/// carries — confirmed against the live endpoint, both on the first page and
/// on a continuation of it. The other two keys are read as well because
/// `feed_parser.dart`'s own reader does, and a panel that grew one should not
/// need an edit here to be noticed.
String? watchContinuationOf(Map<String, Object?> panel) {
  for (final Object? entry in listAt(panel, const <Object>['continuations'])) {
    for (final String key in const <String>[
      'nextRadioContinuationData',
      'nextContinuationData',
      'reloadContinuationData',
    ]) {
      final String? token = stringAt(entry, <Object>[key, 'continuation']);
      if (token != null && token.isNotEmpty) return token;
    }
  }
  return null;
}

/// What the service calls this station, from the queue header.
String? _stationTitle(Map<String, Object?> body) {
  for (final Object? tab in _watchTabs(body)) {
    final Object? header = dig(tab, const <Object>[
      'tabRenderer',
      'content',
      'musicQueueRenderer',
      'header',
      'musicQueueHeaderRenderer',
    ]);
    // `subtitle` rather than `title`: the title is the label "Playing from"
    // and the subtitle is the station's own name — "Never Gonna Give You Up
    // Mix". Confirmed against the live endpoint.
    final String? subtitle = runsTextAt(header, const <Object>[
      'subtitle',
      'runs',
    ]);
    if (subtitle != null && subtitle.trim().isNotEmpty) return subtitle.trim();
  }
  return null;
}

/// The seed a `watchEndpoint`-shaped node names, or `null`.
WatchSeed? _seedOf(Object? endpoint) {
  final String? playlistId = stringAt(endpoint, const <Object>['playlistId']);
  if (playlistId == null || playlistId.isEmpty) return null;
  return WatchSeed(
    videoId: stringAt(endpoint, const <Object>['videoId']),
    playlistId: playlistId,
    params: stringAt(endpoint, const <Object>['params']),
  );
}

/// The "start a station" endpoint a row's overflow menu names, or `null`.
///
/// Found by icon rather than by the menu item's text, for the same reason
/// [relatedBrowseIdOf] goes by page type: "Start mix" is localized and `MIX`
/// is not.
WatchSeed? radioSeedOfRow(Map<String, Object?> renderer) {
  for (final Object? item in listAt(renderer, const <Object>[
    'menu',
    'menuRenderer',
    'items',
  ])) {
    final Map<String, Object?> entry = mapAt(item, const <Object>[
      'menuNavigationItemRenderer',
    ]);
    if (entry.isEmpty) continue;
    final String? icon = stringAt(entry, const <Object>['icon', 'iconType']);
    if (icon != 'MIX' && icon != 'RADIO') continue;
    final WatchSeed? seed = _seedOf(
      dig(entry, const <Object>['navigationEndpoint', 'watchEndpoint']),
    );
    if (seed != null) return seed;
  }
  return null;
}

/// One panel row as a track.
SwayveTrack _trackOf(
  Map<String, Object?> renderer,
  String videoId,
  String title,
  String? musicVideoType,
) {
  final List<Object?> bylineRuns = listAt(renderer, const <Object>[
    'longBylineText',
    'runs',
  ]);
  final List<SwayveArtistRef> artists = artistRefsFromRuns(bylineRuns);
  final WatchSeed? radioSeed = radioSeedOfRow(renderer);
  final String? playlistId = stringAt(renderer, const <Object>[
    'navigationEndpoint',
    'watchEndpoint',
    'playlistId',
  ]);
  final String? fallbackName = _bylineName(renderer);

  return SwayveTrack(
    id: YouTubeMusicIds.mediaId(videoId),
    title: title,
    kind: trackKindForMusicVideoType(musicVideoType),
    // Endpoint-linked runs first, and a plain-text fallback that reads only
    // the *first* segment of the byline. Everything after the first bullet on
    // a watch row is a view count and a like count, so the segment-scanning
    // fallback `item_parser.dart` uses for album-shaped subtitles would
    // happily credit a song to "1.8B views".
    artists: artists.isNotEmpty
        ? artists
        : <SwayveArtistRef>[
            if (fallbackName != null) SwayveArtistRef(name: fallbackName),
          ],
    // No album, deliberately. A watch row never states one — see the library
    // comment at the top of this file — and a guessed release is worse than
    // none: downstream, a guess and a published name are indistinguishable.
    duration: parseClockDuration(
      runsTextAt(renderer, const <Object>['lengthText', 'runs']),
    ),
    artwork: YouTubeMusicArtwork.fromRenderer(
          renderer,
          size: SwayveArtworkSize.large,
        ) ??
        YouTubeMusicArtwork.forVideo(videoId, size: SwayveArtworkSize.large),
    // What the row itself said, rather than an assumption that everything in
    // a station can seed one: the overflow menu carries a "start a station"
    // endpoint exactly when the service will build one around this recording.
    canSeedRadio: radioSeed != null,
    availability: kYouTubeMusicAvailability,
    externalUrl: Uri.parse('https://music.youtube.com/watch?v=$videoId'),
    extra: <String, Object?>{
      if (playlistId != null && playlistId.isNotEmpty) 'playlistId': playlistId,
      // The station this recording would seed, exactly as the service named
      // it. `startRadio` synthesises `RDAMVM<id>` when it has nothing better;
      // this is the something better, for a caller that kept the track.
      if (radioSeed != null) 'radioSeed': radioSeed.toJson(),
    },
  );
}

/// The credit written as plain text on a watch row, when no run linked one.
///
/// The first bullet-separated segment and nothing else. `shortBylineText` is
/// preferred where present because it is exactly the credit with none of the
/// counts attached.
String? _bylineName(Map<String, Object?> renderer) {
  final String? short = runsTextAt(renderer, const <Object>[
    'shortBylineText',
    'runs',
  ]);
  if (short != null && short.trim().isNotEmpty) return short.trim();
  final String? long = runsTextAt(renderer, const <Object>[
    'longBylineText',
    'runs',
  ]);
  final List<String> segments = subtitleSegments(long);
  return segments.isEmpty ? null : segments.first;
}
