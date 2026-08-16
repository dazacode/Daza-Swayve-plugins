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

/// The renderer under [node] named by one of [keys], or `null`.
Map<String, Object?>? _headerIn(Object? node, List<String> keys) {
  final Map<String, Object?> map = mapOf(node);
  if (map.isEmpty) return null;
  for (final String key in keys) {
    final Object? found = map[key];
    if (found != null) return mapOf(found);
  }
  return null;
}

/// The entity header of a browse response, wherever this response put it.
///
/// Three shapes are in circulation and all three still arrive. The oldest hangs
/// the header off the body under `header`. The two-column layout puts it in the
/// first column's section list — which is a *list*, and not always one whose
/// first entry is the header, so every entry is probed rather than index zero
/// alone. A response that describes the entity only in its second column is
/// covered too, because an album browse that carries its listing there
/// sometimes carries the description with it.
Map<String, Object?>? _header(Map<String, Object?> body, List<String> keys) {
  final Map<String, Object?>? direct = _headerIn(body['header'], keys);
  if (direct != null) return direct;

  final List<Object?> sections = <Object?>[
    for (final Object? tab in listAt(body, const <Object>[
      'contents',
      'twoColumnBrowseResultsRenderer',
      'tabs',
    ]))
      ...listAt(tab, const <Object>[
        'tabRenderer',
        'content',
        'sectionListRenderer',
        'contents',
      ]),
    ...listAt(body, const <Object>[
      'contents',
      'twoColumnBrowseResultsRenderer',
      'secondaryContents',
      'sectionListRenderer',
      'contents',
    ]),
  ];

  for (final Object? section in sections) {
    final Map<String, Object?>? found = _headerIn(section, keys);
    if (found != null) return found;
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
///
/// They are also returned on the album rather than only read from, which is
/// the difference between a host that can draw this release and one that has
/// to guess at it from whatever songs it happens to be holding. See
/// [_asListing] for what is stamped onto each of them on the way out.
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
  final SwayveMediaId id = YouTubeMusicIds.mediaId(browseId);
  final SwayveImageRef? cover = YouTubeMusicArtwork.fromRenderer(
        header,
        size: SwayveArtworkSize.large,
      ) ??
      _artworkOfTracks(tracks);

  return SwayveAlbum(
    id: id,
    title: title,
    artists: artists.isNotEmpty
        ? artists
        : <SwayveArtistRef>[
            for (final SwayveArtistRef ref in _artistsOfTracks(tracks)) ref,
          ],
    year: yearFromSegments(segments) ?? yearFromSegments(secondSegments),
    trackCount: countFromSegments(secondSegments) ??
        (tracks.isEmpty ? null : tracks.length),
    artwork: cover,
    availability: kYouTubeMusicAvailability,
    tracks: _asListing(
      tracks,
      id: id,
      title: title,
      cover: cover,
      credited: artists,
    ),
  );
}

/// The album's tracks, each carrying the release it belongs to.
///
/// An album page's rows do not repeat the album's own name, its cover or a
/// position — the page around them says all three, so InnerTube does not send
/// them per row. That is fine for a list drawn under a header and wrong for a
/// track handed to a host, which will file each one on its own and has no page
/// left to read the missing half off.
///
/// So the release is stamped onto every row on the way out:
///
/// * **The album ref**, with its id. A host grouping by title alone cannot tell
///   two different records with the same name apart, and one grouping by the
///   track's own credited artist splits a record with a guest on it into
///   several.
/// * **The position**, from the payload order, when the row did not state one.
///   It is the order the artist put the songs in, and it is the only ordering
///   an album has — falling back to alphabetical would reorder every record in
///   the library.
/// * **The cover**, when the row has none of its own. Every song on a release
///   shares its sleeve, and a page half of whose rows draw initials instead
///   looks broken rather than sparse.
/// * **The credit**, when the row names nobody. An album page's rows are the
///   clearest case of the problem this function exists for: the two-column
///   layout gives each song a title, a running time and an empty second
///   column, because the artist is written once in the header above them.
///   A host filing those rows on their own had nothing to credit them to and
///   wrote "Unknown artist" onto every song of every record opened this way —
///   on the row, in the grouping keys and on the Now Playing screen.
///
/// Nothing already present is overwritten. A row that stated its own album,
/// number, image or artist knows something this function is only inferring —
/// which is what keeps a guest feature credited to the guest rather than
/// overwritten with whoever the record belongs to.
List<SwayveTrack> _asListing(
  List<SwayveTrack> tracks, {
  required SwayveMediaId id,
  required String title,
  required SwayveImageRef? cover,
  List<SwayveArtistRef> credited = const <SwayveArtistRef>[],
}) {
  if (tracks.isEmpty) return const <SwayveTrack>[];
  final SwayveAlbumRef ref = SwayveAlbumRef(id: id, title: title);
  return <SwayveTrack>[
    for (int i = 0; i < tracks.length; i++)
      tracks[i].copyWith(
        album: tracks[i].album == null || tracks[i].album!.id == null
            ? ref
            : tracks[i].album,
        trackNumber: tracks[i].trackNumber ?? i + 1,
        artwork: tracks[i].artwork ?? cover,
        artists: tracks[i].artists.isEmpty ? credited : tracks[i].artists,
      ),
  ];
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
