/// Parsers for the `header` block of a browse response.
///
/// A browse response describes one entity and then lists its contents. The
/// listing is handled generically by `feed_parser.dart`; the header is what
/// says which album or artist you are looking at, and it is the one part whose
/// shape differs per entity kind.
///
/// The distinction these functions preserve is the one the SDK insists on:
/// **absent is not broken**. A body that is structurally a browse response but
/// carries no header for the entity asked about yields `null` — the id no
/// longer resolves — while a body that is not a browse response at all raises
/// `SwayvePluginMalformedResponseException`.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../artwork.dart';
import '../ids.dart';
import '../json_path.dart';
import 'item_parser.dart';

const List<String> _albumHeaderKeys = <String>[
  'musicDetailHeaderRenderer',
  'musicResponsiveHeaderRenderer',
  'musicAlbumReleaseHeaderRenderer',
];

const List<String> _artistHeaderKeys = <String>[
  'musicImmersiveHeaderRenderer',
  'musicVisualHeaderRenderer',
  'musicResponsiveHeaderRenderer',
];

Map<String, Object?>? _header(Map<String, Object?> body, List<String> keys) {
  for (final List<Object> base in const <List<Object>>[
    <Object>['header'],
    <Object>[
      'contents',
      'twoColumnBrowseResultsRenderer',
      'tabs',
      0,
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
      0,
    ],
  ]) {
    final Map<String, Object?> node = mapAt(body, base);
    for (final String key in keys) {
      final Object? found = node[key];
      if (found != null) return mapOf(found);
    }
  }
  return null;
}

void _requireBrowseShape(Map<String, Object?> body, String what) {
  if (body.containsKey('header') ||
      body.containsKey('contents') ||
      body.containsKey('continuationContents')) {
    return;
  }
  malformedResponse('the $what response was not a browse response.');
}

/// Builds an album from a browse response's header.
///
/// [tracks] are the album's own tracks, already parsed from the same
/// response; they supply the track count and the release year when the header
/// does not state them, and their artwork when the header's own image lives on
/// a host the manifest does not declare.
SwayveAlbum? parseAlbumDetail(
  Map<String, Object?> body,
  String browseId, {
  List<SwayveTrack> tracks = const <SwayveTrack>[],
}) {
  _requireBrowseShape(body, 'album');
  final Map<String, Object?>? header = _header(body, _albumHeaderKeys);
  if (header == null) return null;
  final String? title = runsTextAt(header, const <Object>['title', 'runs']);
  if (title == null || title.isEmpty) return null;

  final List<Object?> subtitleRuns = listAt(header, const <Object>[
    'subtitle',
    'runs',
  ]);
  final List<String> segments = subtitleSegments(
    runsTextAt(header, const <Object>['subtitle', 'runs']),
  );
  final List<String> secondSegments = subtitleSegments(
    runsTextAt(header, const <Object>['secondSubtitle', 'runs']),
  );
  final List<SwayveArtistRef> artists = artistRefsFromRuns(subtitleRuns);

  return SwayveAlbum(
    id: YouTubeMusicIds.mediaId(browseId),
    title: title,
    artists: artists.isNotEmpty
        ? artists
        : <SwayveArtistRef>[
            for (final SwayveArtistRef ref in _artistsOfTracks(tracks)) ref,
          ],
    year: yearFromSegments(segments) ?? yearFromSegments(secondSegments),
    trackCount: countFromSegments(secondSegments) ??
        (tracks.isEmpty ? null : tracks.length),
    artwork: YouTubeMusicArtwork.fromRenderer(
          header,
          size: SwayveArtworkSize.large,
        ) ??
        _artworkOfTracks(tracks),
    availability: kYouTubeMusicAvailability,
  );
}

/// Builds an artist from a browse response's header.
SwayveArtist? parseArtistDetail(Map<String, Object?> body, String browseId) {
  _requireBrowseShape(body, 'artist');
  final Map<String, Object?>? header = _header(body, _artistHeaderKeys);
  if (header == null) return null;
  final String? name = runsTextAt(header, const <Object>['title', 'runs']);
  if (name == null || name.isEmpty) return null;

  final String? subscribers = runsTextAt(header, const <Object>[
    'subscriptionButton',
    'subscribeButtonRenderer',
    'subscriberCountText',
    'runs',
  ]);
  final String? description = runsTextAt(header, const <Object>[
    'description',
    'runs',
  ]);

  return SwayveArtist(
    id: YouTubeMusicIds.mediaId(browseId),
    name: name,
    image: YouTubeMusicArtwork.fromRenderer(
      header,
      size: SwayveArtworkSize.large,
    ),
    extra: <String, Object?>{
      if (description != null) 'description': description,
      if (subscribers != null) 'subscriberLabel': subscribers,
    },
  );
}

/// The header image of any browse response, or `null`.
///
/// Used by the artwork provider, which does not care whether the entity is an
/// album, a playlist or an artist — only whether the service published an
/// image for it on a host this plugin is allowed to name.
SwayveImageRef? parseHeaderArtwork(
  Map<String, Object?> body, {
  SwayveArtworkSize size = SwayveArtworkSize.medium,
}) {
  _requireBrowseShape(body, 'artwork');
  final Map<String, Object?>? header = _header(body, const <String>[
    ..._albumHeaderKeys,
    ..._artistHeaderKeys,
  ]);
  if (header == null) return null;
  return YouTubeMusicArtwork.fromRenderer(header, size: size);
}

/// The credited artists of an album's tracks, de-duplicated, in first-seen
/// order.
List<SwayveArtistRef> _artistsOfTracks(List<SwayveTrack> tracks) {
  final List<SwayveArtistRef> result = <SwayveArtistRef>[];
  final Set<String> seen = <String>{};
  for (final SwayveTrack track in tracks) {
    for (final SwayveArtistRef ref in track.artists) {
      if (seen.add(ref.name)) result.add(ref);
    }
  }
  return result;
}

/// The first track artwork available, used when the album header's own image
/// is on an undeclared host.
SwayveImageRef? _artworkOfTracks(List<SwayveTrack> tracks) {
  for (final SwayveTrack track in tracks) {
    final SwayveImageRef? artwork = track.artwork;
    if (artwork != null) return artwork;
  }
  return null;
}
