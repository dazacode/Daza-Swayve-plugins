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

const List<String> _playlistHeaderKeys = <String>[
  'musicResponsiveHeaderRenderer',
  'musicDetailHeaderRenderer',
  'musicEditablePlaylistDetailHeaderRenderer',
];

const List<String> _artistHeaderKeys = <String>[
  'musicImmersiveHeaderRenderer',
  'musicVisualHeaderRenderer',
  'musicResponsiveHeaderRenderer',
];

/// A header renderer together with the key it arrived under.
///
/// The key is carried rather than thrown away because for an artist it decides
/// what the pictures inside the renderer *mean*. `musicImmersiveHeaderRenderer`
/// puts the portrait in `thumbnail`; `musicVisualHeaderRenderer` puts a wide
/// banner there and keeps the artist's wordmark in `foregroundThumbnail`
/// beside it. The two are the same field name holding two different pictures,
/// and a caller that could not tell which renderer it was holding would crop a
/// circular avatar out of the corner of a banner. See [parseArtistDetail].
final class _NamedHeader {
  const _NamedHeader(this.key, this.renderer);

  /// Which of the `_*HeaderKeys` spellings this arrived under.
  final String key;

  /// The renderer's own fields.
  final Map<String, Object?> renderer;
}

/// The renderer under [node] named by one of [keys], or `null`.
_NamedHeader? _headerIn(Object? node, List<String> keys) {
  final Map<String, Object?> map = mapOf(node);
  if (map.isEmpty) return null;
  for (final String key in keys) {
    final Object? found = map[key];
    if (found != null) return _NamedHeader(key, mapOf(found));
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
_NamedHeader? _header(Map<String, Object?> body, List<String> keys) {
  final _NamedHeader? direct = _headerIn(body['header'], keys);
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
    final _NamedHeader? found = _headerIn(section, keys);
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
  final _NamedHeader? found = _header(body, _albumHeaderKeys);
  if (found == null) return null;
  final Map<String, Object?> header = found.renderer;
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
  // The current web header (`musicResponsiveHeaderRenderer`) moved the
  // artist credit out of `subtitle` — which now reads just "Album • 2019" —
  // and into its own `straplineTextOne`, a line drawn above the title the
  // way a byline sits above a headline. The older headers
  // (`musicDetailHeaderRenderer`, `musicAlbumReleaseHeaderRenderer`) never
  // had this field and still say the artist in `subtitle`, so both are read
  // and whichever actually named an artist wins — `subtitle` first, since
  // an older response that somehow carries both should not have a strapline
  // artifact from a different renderer shape override its own credit.
  final List<Object?> straplineRuns = listAt(header, const <Object>[
    'straplineTextOne',
    'runs',
  ]);
  final List<SwayveArtistRef> fromSubtitle = artistRefsFromRuns(subtitleRuns);
  final List<SwayveArtistRef> fromStrapline = artistRefsFromRuns(
    straplineRuns,
  );
  // A strapline naming nobody with a link is still worth reading as plain
  // text — the same last resort `_fallbackArtistName` applies to a track row
  // whose artist run carries no `navigationEndpoint`. Nameless is still
  // better than the empty list that becomes "Unknown artist" two layers up.
  final String? straplineText = runsTextAt(header, const <Object>[
    'straplineTextOne',
    'runs',
  ]);
  final List<SwayveArtistRef> artists = fromSubtitle.isNotEmpty
      ? fromSubtitle
      : fromStrapline.isNotEmpty
          ? fromStrapline
          : <SwayveArtistRef>[
              if (straplineText != null && straplineText.trim().isNotEmpty)
                SwayveArtistRef(name: straplineText.trim()),
            ];
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

/// Builds an artist from a browse response: the header, then the shelves.
///
/// This used to read the header and stop, which is the difference between
/// knowing who somebody is and having anything of theirs to show. Everything
/// an artist page is actually made of — their biggest songs, their records,
/// their singles, the videos, the playlists they turn up on, who else sounds
/// like them — lives below the header in `singleColumnBrowseResultsRenderer`,
/// and none of it was being looked at. See [_artistSections].
///
/// The header itself gave up more than was being taken, too. The subscriber
/// count and the biography were parsed into `extra` and read by nobody; the
/// monthly-listener count, the banner and the play and radio endpoints were
/// not parsed at all. All of them are real fields on `SwayveArtist` now.
SwayveArtist? parseArtistDetail(Map<String, Object?> body, String browseId) {
  _requireBrowseShape(body, 'artist');
  final _NamedHeader? found = _header(body, _artistHeaderKeys);
  if (found == null) return null;
  final Map<String, Object?> header = found.renderer;
  final String? name = runsTextAt(header, const <Object>['title', 'runs']);
  if (name == null || name.isEmpty) return null;

  // The banner is looked for across the whole body rather than only on the
  // header that won, because the two are not the same question. A page whose
  // primary header is `musicImmersiveHeaderRenderer` can still carry a visual
  // header elsewhere, and when the visual header *is* the primary one this
  // finds the very same renderer — so one probe covers both arrangements.
  final _NamedHeader? visual = _header(body, const <String>[
    'musicVisualHeaderRenderer',
  ]);
  final SwayveImageRef? banner = visual == null
      ? null
      : YouTubeMusicArtwork.fromRenderer(
          visual.renderer,
          // `original` rather than `large`: a banner is drawn edge to edge
          // across the top of a page, so the widest rendition the payload
          // names is the one worth asking for. Asking for 544 here would fit a
          // 2560-pixel-wide image into a 544-pixel box and then stretch it
          // back out.
          size: SwayveArtworkSize.original,
        );

  final SwayveMediaId id = YouTubeMusicIds.mediaId(browseId);
  return SwayveArtist(
    id: id,
    name: name,
    image: _artistPortrait(found, banner: banner),
    banner: banner,
    description: _artistDescription(header),
    subscriberLabel: _subscriberLabel(header),
    // The one field this whole pass began over. YouTube Music publishes it on
    // the immersive header and nowhere else — not on the visual header, not on
    // the responsive one — so an artist whose page uses another header shape
    // genuinely has no monthly-listener figure to show, and leaving it null is
    // the honest answer rather than a gap to fill from somewhere else.
    monthlyListenerLabel: runsTextAt(header, const <Object>[
      'monthlyListenerCount',
      'runs',
    ]),
    playAll: _headerEndpoint(header, 'playButton'),
    startRadio: _headerEndpoint(header, 'startRadioButton'),
    sections: _artistSections(
      body,
      credit: SwayveArtistRef(name: name, id: id),
    ),
  );
}

/// The picture of the artist themselves, as opposed to their banner.
///
/// Which field holds it depends on which renderer answered, which is the whole
/// reason [_NamedHeader] carries a key:
///
/// * `musicImmersiveHeaderRenderer` and `musicResponsiveHeaderRenderer` put the
///   portrait in `thumbnail`, so the ordinary renderer probe finds it.
/// * `musicVisualHeaderRenderer` puts a **banner** in `thumbnail` and keeps a
///   second image in `foregroundThumbnail`. That second one is really the
///   artist's wordmark — their name set as a logo, on transparency, meant to be
///   drawn over the banner — rather than a photograph of anybody. It is used
///   here anyway, as both reference clients do, on the same reasoning they
///   apply: it is at least an image *of this artist* at portrait-ish
///   proportions, whereas a circle cropped out of the middle of a 2560×424
///   banner is a piece of somebody's shoulder.
///
/// Falling back to the banner is the last resort, and deliberately still better
/// than nothing: a stretched header image reads as a page that loaded, while a
/// null reads as a grey circle with two initials in it.
SwayveImageRef? _artistPortrait(
  _NamedHeader header, {
  required SwayveImageRef? banner,
}) {
  if (header.key != 'musicVisualHeaderRenderer') {
    return YouTubeMusicArtwork.fromRenderer(
          header.renderer,
          size: SwayveArtworkSize.large,
        ) ??
        banner;
  }
  // `fromRenderer` probes paths that begin at `thumbnail`, so the foreground
  // block is handed to it under that name rather than reimplementing the
  // half-dozen thumbnail spellings it already knows.
  return YouTubeMusicArtwork.fromRenderer(
        <String, Object?>{
          'thumbnail': dig(header.renderer, const <Object>[
            'foregroundThumbnail',
          ]),
        },
        size: SwayveArtworkSize.large,
      ) ??
      banner;
}

/// The artist's biography, wherever this header put it.
///
/// Two spellings, both live. The immersive header writes it straight onto
/// `description`; the responsive header wraps it in a
/// `musicDescriptionShelfRenderer`, exactly as a playlist header does — see
/// [parsePlaylistDetail], which probes the same nesting for the same reason.
String? _artistDescription(Map<String, Object?> header) =>
    runsTextAt(header, const <Object>['description', 'runs']) ??
    runsTextAt(header, const <Object>[
      'description',
      'musicDescriptionShelfRenderer',
      'description',
      'runs',
    ]);

/// How many people follow this artist, in the service's own words.
///
/// Four spellings of the same fact arrive on `subscribeButtonRenderer` and
/// which ones a response carries varies. They are probed in the order that
/// reads best as a standalone label, because that is what the SDK field is —
/// display text, drawn as-is, never re-formatted:
///
/// 1. `longSubscriberCountText` — "1.2M subscribers". A sentence.
/// 2. `subscriberCountWithSubscribeText` — the same with the button's own verb
///    folded in.
/// 3. `subscriberCountText` — usually the sentence too, and what this parser
///    read before the others were added.
/// 4. `shortSubscriberCountText` — "1.2M". Last, because a bare number with no
///    noun on it is a label a host cannot draw without guessing what it counts.
String? _subscriberLabel(Map<String, Object?> header) {
  const List<String> fields = <String>[
    'longSubscriberCountText',
    'subscriberCountWithSubscribeText',
    'subscriberCountText',
    'shortSubscriberCountText',
  ];
  for (final String field in fields) {
    final String? text = runsTextAt(header, <Object>[
      'subscriptionButton',
      'subscribeButtonRenderer',
      field,
      'runs',
    ]);
    if (text != null && text.trim().isNotEmpty) return text.trim();
  }
  return null;
}

/// The collection behind one of the header's buttons, or `null`.
///
/// [button] is `playButton` or `startRadioButton`. Both hang a `watchEndpoint`
/// off a `buttonRenderer`, and both name a playlist and a video on it. The
/// playlist wins: the button means "play this artist" and "start a station",
/// and both of those are collections — the video id is only the track the
/// service would happen to begin with, which is not the same thing and would
/// hand a host one song where a discography was meant.
///
/// The video id is still the fallback, because a button that names only a
/// recording is a button that still does something.
SwayveMediaId? _headerEndpoint(Map<String, Object?> header, String button) {
  final Object? endpoint = dig(header, <Object>[
    button,
    'buttonRenderer',
    'navigationEndpoint',
    'watchEndpoint',
  ]);
  final String? playlistId = stringAt(endpoint, const <Object>['playlistId']);
  if (playlistId != null && playlistId.isNotEmpty) {
    return YouTubeMusicIds.mediaId(playlistId);
  }
  final String? videoId = stringAt(endpoint, const <Object>['videoId']);
  if (videoId == null || videoId.isEmpty) return null;
  return YouTubeMusicIds.mediaId(videoId);
}

/// The shelves of an artist's page, in the order the page put them.
///
/// An artist browse answers with the single-column layout — the same one the
/// home feed uses, which is why nothing here needs the two-column probing
/// [_header] does — and its section list is the page: a `musicShelfRenderer` of
/// rows for the top songs, then a `musicCarouselShelfRenderer` of tiles for
/// each of albums, singles, videos, featured-on playlists and related artists.
///
/// Order is preserved because it is editorial. A service leads with the songs
/// somebody came for and closes with other artists to leave through; sorting
/// the shelves by anything of our own would throw that judgement away and
/// replace it with nothing.
///
/// A shelf that classifies to nothing is dropped rather than kept under some
/// catch-all, matching the SDK enum's own rule: a titled box whose contents a
/// host cannot lay out can only be laid out wrongly.
///
/// [credit] is this page's own artist, stamped onto rows that named nobody —
/// see [_credited].
List<SwayveArtistSection> _artistSections(
  Map<String, Object?> body, {
  required SwayveArtistRef credit,
}) {
  final List<SwayveArtistSection> sections = <SwayveArtistSection>[];
  for (final Object? entry in _sectionListContents(body)) {
    final SwayveArtistSection? section = _artistSection(entry, credit: credit);
    if (section != null) sections.add(section);
  }
  return List<SwayveArtistSection>.unmodifiable(sections);
}

/// The `sectionListRenderer.contents` of the tab that actually holds the page.
///
/// The first tab whose section list has anything in it, rather than `tabs[0]`
/// flatly. An artist page has exactly one tab in every response measured, so in
/// practice these are the same array — but "the first tab that has contents" is
/// true of a one-tab page *and* of the day a second, empty tab appears in front
/// of it, whereas an index is only true until then.
List<Object?> _sectionListContents(Map<String, Object?> body) {
  for (final Object? tab in listAt(body, const <Object>[
    'contents',
    'singleColumnBrowseResultsRenderer',
    'tabs',
  ])) {
    final List<Object?> contents = listAt(tab, const <Object>[
      'tabRenderer',
      'content',
      'sectionListRenderer',
      'contents',
    ]);
    if (contents.isNotEmpty) return contents;
  }
  return const <Object?>[];
}

/// One entry of the section list as a section, or `null` if it is not a shelf.
///
/// The two shelf renderers differ in where they keep their heading and in what
/// they hold, and in nothing else that matters here:
///
/// * `musicShelfRenderer` — a list of `musicResponsiveListItemRenderer` rows,
///   heading directly on `title`, and the heading's own first run carries the
///   "more" endpoint when there is one. This is the top-songs shelf.
/// * `musicCarouselShelfRenderer` — a strip of `musicTwoRowItemRenderer` tiles,
///   heading nested in `header.musicCarouselShelfBasicHeaderRenderer`, and a
///   separate `moreContentButton` for the "more" endpoint. Everything that is
///   not songs arrives this way.
///
/// Anything else in the list — a divider, an "about" shelf, a continuation
/// item — is not a shelf of items and yields `null` rather than an empty
/// section.
SwayveArtistSection? _artistSection(
  Object? entry, {
  required SwayveArtistRef credit,
}) {
  final Map<String, Object?> map = mapOf(entry);

  final Object? shelf = map['musicShelfRenderer'];
  if (shelf != null) {
    final Map<String, Object?> renderer = mapOf(shelf);
    return _buildSection(
      contents: listAt(renderer, const <Object>['contents']),
      title: runsTextAt(renderer, const <Object>['title', 'runs']),
      more: _browseEndpointAt(renderer, const <Object>[
        'title',
        'runs',
        0,
        'navigationEndpoint',
      ]),
      credit: credit,
    );
  }

  final Object? carousel = map['musicCarouselShelfRenderer'];
  if (carousel != null) {
    final Map<String, Object?> renderer = mapOf(carousel);
    const List<Object> headerPath = <Object>[
      'header',
      'musicCarouselShelfBasicHeaderRenderer',
    ];
    return _buildSection(
      contents: listAt(renderer, const <Object>['contents']),
      title: runsTextAt(renderer, const <Object>[
        ...headerPath,
        'title',
        'runs',
      ]),
      // The button first and the heading's own link second. A carousel that
      // offers both points them at the same page; a carousel that offers one
      // is much more often the button.
      more: _browseEndpointAt(renderer, const <Object>[
            ...headerPath,
            'moreContentButton',
            'buttonRenderer',
            'navigationEndpoint',
          ]) ??
          _browseEndpointAt(renderer, const <Object>[
            ...headerPath,
            'title',
            'runs',
            0,
            'navigationEndpoint',
          ]),
      credit: credit,
    );
  }

  return null;
}

/// Assembles one shelf, or `null` when there is nothing in it to file.
SwayveArtistSection? _buildSection({
  required List<Object?> contents,
  required String? title,
  required SwayveMediaId? more,
  required SwayveArtistRef credit,
}) {
  if (contents.isEmpty) return null;
  final ItemCollector items = ItemCollector()..addAll(contents);
  final SwayveArtistSectionKind? kind = _sectionKind(items, contents);
  if (kind == null) return null;

  return SwayveArtistSection(
    kind: kind,
    title: title == null || title.trim().isEmpty ? null : title.trim(),
    tracks: _credited(items.tracks, credit),
    albums: items.albums,
    artists: items.artists,
    playlists: items.playlists,
    more: more,
  );
}

/// What a shelf is a shelf of, decided from its contents.
///
/// Never from the heading. "Top songs" is "Canciones principales" for a Spanish
/// listener and "गाने" for a Hindi one, and a parser keying off those words
/// would classify every shelf correctly in English and nothing at all
/// elsewhere. Both reference clients reached the same conclusion.
///
/// Two of the six kinds need a second question after the item type, because
/// two pairs of shelves hold the same kind of item:
///
/// * **Songs against videos.** Already answered per item, upstream: every watch
///   endpoint states a `musicVideoType`, and `ItemCollector` has turned it into
///   `SwayveTrackKind` before this sees it. Read off the first track, since the
///   shelf takes its identity from its first item everywhere else here too.
/// * **Albums against singles.** See [_looksLikeSingles].
SwayveArtistSectionKind? _sectionKind(
  ItemCollector items,
  List<Object?> contents,
) =>
    switch (items.firstKind) {
      YouTubeMusicIdKind.track => items.tracks.isNotEmpty &&
              items.tracks.first.kind == SwayveTrackKind.video
          ? SwayveArtistSectionKind.videos
          : SwayveArtistSectionKind.topSongs,
      YouTubeMusicIdKind.album => _looksLikeSingles(contents)
          ? SwayveArtistSectionKind.singles
          : SwayveArtistSectionKind.albums,
      YouTubeMusicIdKind.playlist => SwayveArtistSectionKind.playlists,
      YouTubeMusicIdKind.artist => SwayveArtistSectionKind.relatedArtists,
      null => null,
    };

/// Whether a shelf of releases is the singles shelf rather than the albums one.
///
/// The two shelves are made of identical tiles pointing at identical browse
/// ids, and the only thing that separates them in the payload is how much the
/// subtitle says. An albums tile writes the type and the year — `Album`, `•`,
/// `2023`, three runs — while a singles tile writes the year alone, one run.
/// So: one subtitle run that reads as a year means singles.
///
/// Both halves of that test are needed. Run count alone would call any
/// one-word subtitle a single, and "is it a year" alone would match the last
/// run of `Album • 2023` just as well.
///
/// **Its limits, stated rather than hidden.** This reads a *shape*, not a word,
/// which is the only kind of test that survives translation — the word "Single"
/// is "Sencillo" and "सिंगल", so matching on it would work in English and
/// nowhere else, exactly the failure this whole file is arranged to avoid. The
/// price is that a market whose singles tiles do spell out the type falls to
/// [SwayveArtistSectionKind.albums]: those releases appear on the page, under
/// the wrong one of two headings. That is a visibly smaller loss than dropping
/// them, and a much smaller one than a parser that works in one language.
///
/// Decided from the first tile that has a subtitle at all, for the same reason
/// `ItemCollector.firstKind` looks at the first item: a shelf is one thing, and
/// its first entry is what it is about.
bool _looksLikeSingles(List<Object?> contents) {
  for (final Object? entry in contents) {
    final List<Object?> runs = listAt(entry, const <Object>[
      'musicTwoRowItemRenderer',
      'subtitle',
      'runs',
    ]);
    if (runs.isEmpty) continue;
    if (runs.length != 1) return false;
    final String? text = stringAt(runs.first, const <Object>['text']);
    return yearFromSegments(subtitleSegments(text)) != null;
  }
  return false;
}

/// The browse id of the endpoint at [path], as a media id, or `null`.
SwayveMediaId? _browseEndpointAt(Object? node, List<Object> path) {
  final String? browseId = stringAt(node, <Object>[
    ...path,
    'browseEndpoint',
    'browseId',
  ]);
  if (browseId == null || browseId.isEmpty) return null;
  return YouTubeMusicIds.mediaId(browseId);
}

/// [tracks] with the page's own artist stamped onto any row that named nobody.
///
/// The same problem an album page has, from the other direction. An artist
/// page's rows do not repeat the artist's name — the page is titled with it, so
/// InnerTube leaves the flex column to the album or the play count instead —
/// and a host filing those rows on their own has nothing to credit them to. It
/// wrote "Unknown artist" onto every top song of every artist opened this way,
/// on the row, in the grouping keys and on the Now Playing screen.
///
/// Only rows that credited nobody are touched. A row that named its own artists
/// knows something this is only inferring, and that is exactly the case of a
/// guest feature, which must stay credited to the guest.
List<SwayveTrack> _credited(List<SwayveTrack> tracks, SwayveArtistRef credit) {
  if (tracks.isEmpty) return const <SwayveTrack>[];
  return List<SwayveTrack>.unmodifiable(<SwayveTrack>[
    for (final SwayveTrack track in tracks)
      track.artists.isEmpty
          ? track.copyWith(artists: <SwayveArtistRef>[credit])
          : track,
  ]);
}

/// Builds a playlist from a browse response's header.
///
/// The same three header shapes an album arrives under, because a playlist
/// arrives under them too: confirmed against the live endpoint, a curated
/// `RDCLAK…` playlist and a community `PL…` one both answer with a
/// `musicResponsiveHeaderRenderer` in the first column and a
/// `musicPlaylistShelfRenderer` of rows in the second — which is why nothing
/// here parses a track and `feed_parser.dart` is left to do it.
///
/// [tracks] are that shelf, already parsed, and supply the count when the
/// header does not state one.
///
/// `null` — never an exception — for a body that is structurally a browse
/// response but describes no playlist: an id the service no longer resolves.
SwayvePlaylist? parsePlaylistDetail(
  Map<String, Object?> body,
  String browseId, {
  List<SwayveTrack> tracks = const <SwayveTrack>[],
}) {
  _requireBrowseShape(body, 'playlist');
  final _NamedHeader? found = _header(body, _playlistHeaderKeys);
  if (found == null) return null;
  final Map<String, Object?> header = found.renderer;
  final String? title = runsTextAt(header, const <Object>['title', 'runs']);
  if (title == null || title.isEmpty) return null;

  // Both subtitle lines are read, because they carry different halves of the
  // description and which half lands where varies per playlist. Measured: a
  // curated playlist writes `Playlist • 2026` on the first and
  // `132 songs • 7+ hours` on the second; a community one writes
  // `8.3K views • 20 tracks • 1 hour, 23 minutes` on the second.
  final List<Object?> subtitleRuns = listAt(header, const <Object>[
    'subtitle',
    'runs',
  ]);
  final List<String> secondSegments = subtitleSegments(
    runsTextAt(header, const <Object>['secondSubtitle', 'runs']),
  );
  final List<String> segments = subtitleSegments(
    runsTextAt(header, const <Object>['subtitle', 'runs']),
  );

  // The owner, when a run links to a channel. A curated playlist links
  // nobody — it is YouTube Music's own — and leaving that null is the honest
  // answer rather than crediting it to the first word of the subtitle, which
  // is the localized word "Playlist".
  final List<SwayveArtistRef> owners = <SwayveArtistRef>[
    ...artistRefsFromRuns(subtitleRuns),
    ...artistRefsFromRuns(
      listAt(header, const <Object>['straplineTextOne', 'runs']),
    ),
  ];

  final String? description = runsTextAt(header, const <Object>[
    'description',
    'musicDescriptionShelfRenderer',
    'description',
    'runs',
  ]);

  return SwayvePlaylist(
    id: YouTubeMusicIds.mediaId(browseId),
    title: title,
    description: description,
    ownerName: owners.isEmpty ? null : owners.first.name,
    trackCount: countFromSegments(secondSegments) ??
        countFromSegments(segments) ??
        (tracks.isEmpty ? null : tracks.length),
    artwork: YouTubeMusicArtwork.fromRenderer(
          header,
          size: SwayveArtworkSize.large,
        ) ??
        _artworkOfTracks(tracks),
    extra: <String, Object?>{
      'browseId': YouTubeMusicIds.playlistBrowseId(browseId),
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
  final _NamedHeader? found = _header(body, const <String>[
    ..._albumHeaderKeys,
    ..._artistHeaderKeys,
    ..._playlistHeaderKeys,
  ]);
  if (found == null) return null;
  return YouTubeMusicArtwork.fromRenderer(found.renderer, size: size);
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
