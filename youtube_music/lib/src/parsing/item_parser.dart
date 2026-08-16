import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../artwork.dart';
import '../ids.dart';
import '../json_path.dart';

/// Turns one InnerTube item renderer into one normalized SDK model.
///
/// Two shapes cover almost everything YouTube Music returns:
/// `musicResponsiveListItemRenderer` for list rows (search results, album
/// track lists) and `musicTwoRowItemRenderer` for carousel tiles (the browse
/// feeds). Both are handled here so that the search parser and the browse
/// parser share one notion of what a track is.
///
/// **Classification is by endpoint, never by shelf title.** A shelf headed
/// "Songs" is headed "Canciones" for a Spanish user and "गाने" for a Hindi
/// one, so keying off it would make the plugin work in English and quietly
/// return nothing everywhere else. Every item instead declares what it is in
/// its navigation endpoint: a `watchEndpoint` carries a video id and means a
/// track, and a `browseEndpoint` carries a `pageType` of
/// `MUSIC_PAGE_TYPE_ALBUM`, `..._ARTIST` or `..._PLAYLIST`. Those tokens are
/// not localized.
///
/// **An item that cannot be understood is skipped, not fatal.** One renamed
/// field should cost the user one row, not the whole search. The collector
/// records that it happened so the caller can set `SwayveSearchResult.partial`
/// and the host can say results may be missing.
final class ItemCollector {
  /// Creates an empty collector.
  ItemCollector();

  /// Tracks parsed so far, in payload order.
  final List<SwayveTrack> tracks = <SwayveTrack>[];

  /// Albums parsed so far, in payload order.
  final List<SwayveAlbum> albums = <SwayveAlbum>[];

  /// Artists parsed so far, in payload order.
  final List<SwayveArtist> artists = <SwayveArtist>[];

  /// Playlists parsed so far, in payload order.
  final List<SwayvePlaylist> playlists = <SwayvePlaylist>[];

  /// Whether at least one item was skipped because it could not be read.
  bool skippedItems = false;

  /// Whether nothing at all was collected.
  bool get isEmpty =>
      tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty;

  /// Parses every entry of an InnerTube `contents` array into this collector.
  void addAll(List<Object?> contents) {
    for (final Object? entry in contents) {
      add(entry);
    }
  }

  /// Parses one InnerTube item wrapper into this collector.
  void add(Object? wrapper) {
    final Map<String, Object?> map = mapOf(wrapper);
    final Object? listItem = map['musicResponsiveListItemRenderer'];
    if (listItem != null) {
      _collect(_ListItemReader(mapOf(listItem)));
      return;
    }
    final Object? tile = map['musicTwoRowItemRenderer'];
    if (tile != null) {
      _collect(_TwoRowReader(mapOf(tile)));
      return;
    }
    // Shelf dividers, "show more" buttons and section headers all arrive in
    // the same array. They are not items and their absence is not a defect,
    // so they do not set `skippedItems`.
  }

  void _collect(_ItemReader reader) {
    final _Endpoint? endpoint = reader.endpoint;
    final String? title = reader.title;
    if (endpoint == null || title == null || title.isEmpty) {
      skippedItems = true;
      return;
    }
    switch (endpoint.kind) {
      case YouTubeMusicIdKind.track:
        tracks.add(reader.toTrack(endpoint.id, title));
      case YouTubeMusicIdKind.album:
        albums.add(reader.toAlbum(endpoint.id, title));
      case YouTubeMusicIdKind.artist:
        artists.add(reader.toArtist(endpoint.id, title));
      case YouTubeMusicIdKind.playlist:
        playlists.add(reader.toPlaylist(endpoint.id, title));
    }
  }
}

/// What an item's navigation endpoint resolved to.
final class _Endpoint {
  const _Endpoint(this.kind, this.id);

  final YouTubeMusicIdKind kind;
  final String id;
}

/// The endpoint carried by [node], or `null` when there is not a usable one.
_Endpoint? _readEndpoint(Object? node) {
  final String? videoId = stringAt(node, const <Object>[
    'watchEndpoint',
    'videoId',
  ]);
  if (videoId != null && videoId.isNotEmpty) {
    return _Endpoint(YouTubeMusicIdKind.track, videoId);
  }
  final String? browseId = stringAt(node, const <Object>[
    'browseEndpoint',
    'browseId',
  ]);
  if (browseId == null || browseId.isEmpty) return null;
  final String? pageType = stringAt(node, const <Object>[
    'browseEndpoint',
    'browseEndpointContextSupportedConfigs',
    'browseEndpointContextMusicConfig',
    'pageType',
  ]);
  final YouTubeMusicIdKind? kind = switch (pageType) {
    'MUSIC_PAGE_TYPE_ALBUM' => YouTubeMusicIdKind.album,
    'MUSIC_PAGE_TYPE_ARTIST' => YouTubeMusicIdKind.artist,
    'MUSIC_PAGE_TYPE_USER_CHANNEL' => YouTubeMusicIdKind.artist,
    'MUSIC_PAGE_TYPE_PLAYLIST' => YouTubeMusicIdKind.playlist,
    // No page type: fall back to the id's own shape, which is how YouTube
    // itself distinguishes a browse id.
    _ => YouTubeMusicIds.classify(browseId),
  };
  return kind == null ? null : _Endpoint(kind, browseId);
}

/// An artist reference for every subtitle run that links to an artist page.
List<SwayveArtistRef> artistRefsFromRuns(List<Object?> runs) {
  final List<SwayveArtistRef> refs = <SwayveArtistRef>[];
  for (final Object? run in runs) {
    final String? text = stringAt(run, const <Object>['text']);
    if (text == null || text.trim().isEmpty) continue;
    final _Endpoint? endpoint = _readEndpoint(
      dig(run, const <Object>[
        'navigationEndpoint',
      ]),
    );
    if (endpoint?.kind == YouTubeMusicIdKind.artist) {
      refs.add(
        SwayveArtistRef(
          name: text.trim(),
          id: YouTubeMusicIds.mediaId(endpoint!.id),
        ),
      );
    }
  }
  return refs;
}

/// The album reference carried by a subtitle run, if one links to an album.
SwayveAlbumRef? albumRefFromRuns(List<Object?> runs) {
  for (final Object? run in runs) {
    final String? text = stringAt(run, const <Object>['text']);
    if (text == null || text.trim().isEmpty) continue;
    final _Endpoint? endpoint = _readEndpoint(
      dig(run, const <Object>[
        'navigationEndpoint',
      ]),
    );
    if (endpoint?.kind == YouTubeMusicIdKind.album) {
      return SwayveAlbumRef(
        title: text.trim(),
        id: YouTubeMusicIds.mediaId(endpoint!.id),
      );
    }
  }
  return null;
}

final RegExp _separator = RegExp(r'\s*[•·]\s*');
final RegExp _yearPattern = RegExp(r'^(19|20)\d{2}$');
final RegExp _countPattern = RegExp(r'^(\d[\d,\.]*)\s+\S+$');

/// The `•`-separated segments of a subtitle, trimmed and non-empty.
///
/// The fallback path: when no run carries an endpoint, the display text is all
/// there is, and YouTube Music writes subtitles as `Artist • Album • 3:32` or
/// `Album • Artist • 2019`.
List<String> subtitleSegments(String? subtitle) {
  if (subtitle == null) return const <String>[];
  return subtitle
      .split(_separator)
      .map((String segment) => segment.trim())
      .where((String segment) => segment.isNotEmpty)
      .toList();
}

/// The four-digit year among [segments], or `null`.
int? yearFromSegments(List<String> segments) {
  for (final String segment in segments) {
    if (_yearPattern.hasMatch(segment)) return int.tryParse(segment);
  }
  return null;
}

/// The clock duration among [segments], or `null`.
Duration? durationFromSegments(List<String> segments) {
  for (final String segment in segments) {
    final Duration? parsed = parseClockDuration(segment);
    if (parsed != null) return parsed;
  }
  return null;
}

/// A leading count such as `12 songs` among [segments], or `null`.
int? countFromSegments(List<String> segments) {
  for (final String segment in segments) {
    if (_yearPattern.hasMatch(segment)) continue;
    final RegExpMatch? match = _countPattern.firstMatch(segment);
    if (match == null) continue;
    final String digits = match.group(1)!.replaceAll(RegExp(r'[,\.]'), '');
    final int? value = int.tryParse(digits);
    if (value != null) return value;
  }
  return null;
}

/// Whether [badges] contains YouTube Music's explicit-content badge.
bool hasExplicitBadge(List<Object?> badges) {
  for (final Object? badge in badges) {
    final String? icon = stringAt(badge, const <Object>[
      'musicInlineBadgeRenderer',
      'icon',
      'iconType',
    ]);
    if (icon == 'MUSIC_EXPLICIT_BADGE') return true;
  }
  return false;
}

/// The availability every item from this provider reports.
///
/// Principle 6, stated once so it cannot drift: YouTube Music items are
/// playable over the network, are **not** downloadable — this plugin resolves
/// playback to the service's own embedded player and holds no offline rights
/// (see the README) — and are never already on the device.
const SwayveAvailability kYouTubeMusicAvailability = SwayveAvailability(
  streamable: true,
  downloadable: false,
  onDevice: false,
);

/// The behaviour shared by both renderer shapes.
abstract class _ItemReader {
  _ItemReader(this.renderer);

  final Map<String, Object?> renderer;

  _Endpoint? get endpoint;

  String? get title;

  List<Object?> get subtitleRuns;

  List<Object?> get badges;

  String? get subtitleText => runsTextAt(renderer, subtitlePath);

  List<Object> get subtitlePath;

  SwayveImageRef? artwork({
    SwayveArtworkSize size = SwayveArtworkSize.medium,
  }) =>
      YouTubeMusicArtwork.fromRenderer(renderer, size: size);

  /// The playlist a track was surfaced from, when the payload names one.
  String? get playlistId => stringAt(renderer, const <Object>[
        'overlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
        'watchEndpoint',
        'playlistId',
      ]);

  Duration? get explicitDuration => null;

  int? get trackNumber => null;

  SwayveTrack toTrack(String videoId, String title) {
    final List<String> segments = subtitleSegments(subtitleText);
    final List<SwayveArtistRef> artists = artistRefsFromRuns(subtitleRuns);
    final String? playlist = playlistId;
    return SwayveTrack(
      id: YouTubeMusicIds.mediaId(videoId),
      title: title,
      artists: artists.isNotEmpty
          ? artists
          : <SwayveArtistRef>[
              if (_fallbackArtistName(segments) case final String name)
                SwayveArtistRef(name: name),
            ],
      album: albumRefFromRuns(subtitleRuns),
      duration: explicitDuration ?? durationFromSegments(segments),
      trackNumber: trackNumber,
      year: yearFromSegments(segments),
      // The record's own sleeve first, and the video's frame only if there
      // isn't one.
      //
      // The order matters more than it looks. `i.ytimg.com` publishes frames
      // from the video — 16:9, letterboxed, and often a still of whatever was
      // on screen — while the payload carries the square cover the service
      // actually draws. Anything rendering a sleeve gets the first as a
      // stretched, low-resolution mess and the second as the artwork.
      //
      // The fallback is still worth having: a track that is genuinely a video
      // rather than a release may carry no square art at all, and a frame from
      // it beats a placeholder with initials on it.
      artwork: artwork(size: SwayveArtworkSize.large) ??
          YouTubeMusicArtwork.forVideo(
            videoId,
            size: SwayveArtworkSize.large,
          ),
      explicit: hasExplicitBadge(badges),
      availability: kYouTubeMusicAvailability,
      extra: <String, Object?>{
        if (playlist != null && playlist.isNotEmpty) 'playlistId': playlist,
      },
    );
  }

  SwayveAlbum toAlbum(String browseId, String title) {
    final List<String> segments = subtitleSegments(subtitleText);
    final List<SwayveArtistRef> artists = artistRefsFromRuns(subtitleRuns);
    return SwayveAlbum(
      id: YouTubeMusicIds.mediaId(browseId),
      title: title,
      artists: artists.isNotEmpty
          ? artists
          : <SwayveArtistRef>[
              if (_fallbackArtistName(segments) case final String name)
                SwayveArtistRef(name: name),
            ],
      year: yearFromSegments(segments),
      trackCount: countFromSegments(segments),
      artwork: artwork(size: SwayveArtworkSize.large),
      availability: kYouTubeMusicAvailability,
    );
  }

  SwayveArtist toArtist(String browseId, String name) => SwayveArtist(
        id: YouTubeMusicIds.mediaId(browseId),
        name: name,
        image: artwork(size: SwayveArtworkSize.large),
      );

  SwayvePlaylist toPlaylist(String browseId, String title) {
    final List<String> segments = subtitleSegments(subtitleText);
    final List<SwayveArtistRef> owners = artistRefsFromRuns(subtitleRuns);
    return SwayvePlaylist(
      id: YouTubeMusicIds.mediaId(browseId),
      title: title,
      ownerName:
          owners.isNotEmpty ? owners.first.name : _fallbackArtistName(segments),
      trackCount: countFromSegments(segments),
      artwork: artwork(size: SwayveArtworkSize.large),
      extra: <String, Object?>{
        'browseId': YouTubeMusicIds.playlistBrowseId(browseId),
      },
    );
  }

  /// The first subtitle segment that is not a year, a duration or a count.
  ///
  /// Only reached when no run carried an artist endpoint. It is a heuristic
  /// over display text, so it is deliberately the last resort rather than the
  /// first: a wrong guess here shows a slightly wrong label, whereas trusting
  /// it over an endpoint would break navigation.
  String? _fallbackArtistName(List<String> segments) {
    for (final String segment in segments) {
      if (_yearPattern.hasMatch(segment)) continue;
      if (parseClockDuration(segment) != null) continue;
      if (_countPattern.hasMatch(segment)) continue;
      if (_typeWords.contains(segment.toLowerCase())) continue;
      return segment;
    }
    return null;
  }

  static const Set<String> _typeWords = <String>{
    'song',
    'video',
    'album',
    'single',
    'ep',
    'playlist',
    'artist',
  };
}

/// A list row: search results and album track listings.
final class _ListItemReader extends _ItemReader {
  _ListItemReader(super.renderer);

  @override
  List<Object> get subtitlePath => const <Object>[
        'flexColumns',
        1,
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
      ];

  @override
  _Endpoint? get endpoint {
    // The play button is the most reliable source of a video id: a row whose
    // title run links to the artist still plays the right recording.
    final _Endpoint? fromOverlay = _readEndpoint(
      dig(renderer, const <Object>[
        'overlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
      ]),
    );
    if (fromOverlay != null) return fromOverlay;

    final String? fromPlaylistData = stringAt(renderer, const <Object>[
      'playlistItemData',
      'videoId',
    ]);
    if (fromPlaylistData != null && fromPlaylistData.isNotEmpty) {
      return _Endpoint(YouTubeMusicIdKind.track, fromPlaylistData);
    }

    final _Endpoint? fromTitleRun = _readEndpoint(
      dig(renderer, const <Object>[
        'flexColumns',
        0,
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
        0,
        'navigationEndpoint',
      ]),
    );
    if (fromTitleRun != null) return fromTitleRun;

    return _readEndpoint(dig(renderer, const <Object>['navigationEndpoint']));
  }

  @override
  String? get title => runsTextAt(renderer, const <Object>[
        'flexColumns',
        0,
        'musicResponsiveListItemFlexColumnRenderer',
        'text',
        'runs',
      ]);

  @override
  List<Object?> get subtitleRuns => listAt(renderer, subtitlePath);

  @override
  List<Object?> get badges => listAt(renderer, const <Object>['badges']);

  /// Album track listings put the running time in a fixed column instead of
  /// the subtitle.
  @override
  Duration? get explicitDuration => parseClockDuration(
        runsTextAt(renderer, const <Object>[
          'fixedColumns',
          0,
          'musicResponsiveListItemFixedColumnRenderer',
          'text',
          'runs',
        ]),
      );

  @override
  int? get trackNumber {
    final String? label = runsTextAt(renderer, const <Object>['index', 'runs']);
    return label == null ? null : int.tryParse(label.trim());
  }
}

/// A carousel tile: the browse feeds.
final class _TwoRowReader extends _ItemReader {
  _TwoRowReader(super.renderer);

  @override
  List<Object> get subtitlePath => const <Object>['subtitle', 'runs'];

  @override
  _Endpoint? get endpoint =>
      _readEndpoint(dig(renderer, const <Object>['navigationEndpoint'])) ??
      _readEndpoint(
        dig(renderer, const <Object>[
          'thumbnailOverlay',
          'musicItemThumbnailOverlayRenderer',
          'content',
          'musicPlayButtonRenderer',
          'playNavigationEndpoint',
        ]),
      );

  @override
  String? get title => runsTextAt(renderer, const <Object>['title', 'runs']);

  @override
  List<Object?> get subtitleRuns => listAt(renderer, subtitlePath);

  @override
  List<Object?> get badges =>
      listAt(renderer, const <Object>['subtitleBadges']);

  @override
  String? get playlistId => stringAt(renderer, const <Object>[
        'thumbnailOverlay',
        'musicItemThumbnailOverlayRenderer',
        'content',
        'musicPlayButtonRenderer',
        'playNavigationEndpoint',
        'watchEndpoint',
        'playlistId',
      ]);
}
