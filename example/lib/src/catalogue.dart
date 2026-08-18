/// The plugin's data: a hand-written catalogue, and the normalization that
/// turns it into SDK models.
///
/// ## Why the raw shape and the SDK shape are different types
///
/// The `_raw*` records below are deliberately ugly. They spell an artist
/// credit as one string, a duration as an integer of seconds, and a
/// relationship as a bare identifier — which is how nearly every real music
/// API spells them, and no two of them agree on the details.
///
/// The SDK models are the opposite: artists are always a list of
/// `SwayveArtistRef`, durations are always a `Duration`, and identifiers are
/// always a `SwayveMediaId` that says which plugin minted them.
///
/// Converting between the two is this file's only job, and it happens **at the
/// plugin's boundary** — before any value reaches a provider, and long before
/// one reaches the host. That is what makes the host provider-agnostic: it
/// renders a `SwayveTrack` the same way whether it came from a fixture, from
/// YouTube Music, or from something that does not exist yet. If normalization
/// leaked further in, every host feature would have to learn every provider's
/// dialect, and principle 2 — the client has zero hardcoded knowledge of any
/// specific plugin — would quietly stop being true.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// This plugin's id, identical to `id` in `plugin.json`.
///
/// It is also the `pluginId` of every [SwayveMediaId] the plugin mints, which
/// is what makes those ids globally unique: two plugins may both call a track
/// `1`, and the host can still tell them apart and route a request back to
/// whichever plugin owns it.
const String examplePluginId = 'app.swayve.plugins.example';

/// The upstream shape of an artist. Stands in for a decoded API response.
typedef _RawArtist = ({String id, String name, List<String> genres});

/// The upstream shape of an album.
typedef _RawAlbum = ({String id, String title, String artistId, int year});

/// The upstream shape of a track.
///
/// Note `credit`: one string holding possibly several artists, which is the
/// single most common thing a plugin has to un-mangle.
typedef _RawTrack = ({
  String id,
  String title,
  String credit,
  String albumId,
  int lengthSeconds,
  int trackNumber,
});

const List<_RawArtist> _rawArtists = [
  (
    id: 'nadia-okonkwo',
    name: 'Nadia Okonkwo',
    genres: ['ambient', 'modern classical'],
  ),
  (id: 'the-ferrous-sea', name: 'The Ferrous Sea', genres: ['post-rock']),
  (id: 'halcyon-bureau', name: 'Halcyon Bureau', genres: ['downtempo', 'dub']),
];

const List<_RawAlbum> _rawAlbums = [
  (
    id: 'low-tide-hours',
    title: 'Low Tide Hours',
    artistId: 'nadia-okonkwo',
    year: 2019,
  ),
  (
    id: 'iron-in-the-water',
    title: 'Iron in the Water',
    artistId: 'the-ferrous-sea',
    year: 2021,
  ),
  (
    id: 'bureau-tapes',
    title: 'Bureau Tapes',
    artistId: 'halcyon-bureau',
    year: 2023,
  ),
];

const List<_RawTrack> _rawTracks = [
  (
    id: 'first-light',
    title: 'First Light',
    credit: 'Nadia Okonkwo',
    albumId: 'low-tide-hours',
    lengthSeconds: 214,
    trackNumber: 1,
  ),
  (
    id: 'low-tide-hours',
    title: 'Low Tide Hours',
    credit: 'Nadia Okonkwo',
    albumId: 'low-tide-hours',
    lengthSeconds: 331,
    trackNumber: 2,
  ),
  (
    id: 'salt-and-paper',
    title: 'Salt and Paper',
    credit: 'Nadia Okonkwo & Halcyon Bureau',
    albumId: 'low-tide-hours',
    lengthSeconds: 268,
    trackNumber: 3,
  ),
  (
    id: 'anvil-choir',
    title: 'Anvil Choir',
    credit: 'The Ferrous Sea',
    albumId: 'iron-in-the-water',
    lengthSeconds: 402,
    trackNumber: 1,
  ),
  (
    id: 'iron-in-the-water',
    title: 'Iron in the Water',
    credit: 'The Ferrous Sea',
    albumId: 'iron-in-the-water',
    lengthSeconds: 355,
    trackNumber: 2,
  ),
  (
    id: 'the-long-weld',
    title: 'The Long Weld',
    credit: 'The Ferrous Sea & Wren Adeyemi',
    albumId: 'iron-in-the-water',
    lengthSeconds: 287,
    trackNumber: 3,
  ),
  (
    id: 'night-bus-dub',
    title: 'Night Bus Dub',
    credit: 'Halcyon Bureau',
    albumId: 'bureau-tapes',
    lengthSeconds: 244,
    trackNumber: 1,
  ),
  (
    id: 'paper-lanterns',
    title: 'Paper Lanterns',
    credit: 'Halcyon Bureau & Nadia Okonkwo',
    albumId: 'bureau-tapes',
    lengthSeconds: 199,
    trackNumber: 2,
  ),
];

/// Everything this plugin knows, already normalized.
///
/// A real plugin's equivalent is a client for its service. The interesting
/// property is not that this one is in-memory, it is that the providers in
/// `providers.dart` only ever see SDK types: they never learn that a duration
/// arrived as an integer or that an artist credit arrived as a string.
final class ExampleCatalogue {
  /// Creates a catalogue over already-normalized models.
  const ExampleCatalogue({
    this.artists = const <SwayveArtist>[],
    this.albums = const <SwayveAlbum>[],
    this.tracks = const <SwayveTrack>[],
  });

  /// The catalogue the shipping plugin serves.
  ///
  /// Built once, lazily, on first use — normalization is cheap here but it is
  /// still work, and a plugin should not do work the host has not asked for.
  static final ExampleCatalogue fixture = _buildFixtureCatalogue();

  /// A catalogue with nothing in it.
  ///
  /// Useful in tests: "found nothing" and "failed" are different facts, and a
  /// provider must be able to report the first without inventing the second.
  static const ExampleCatalogue empty = ExampleCatalogue();

  /// Every artist, in fixture order.
  final List<SwayveArtist> artists;

  /// Every album, in fixture order.
  final List<SwayveAlbum> albums;

  /// Every track, in album then track-number order.
  final List<SwayveTrack> tracks;

  /// The album whose media id has this [value], or `null` if there is none.
  ///
  /// `null` is the honest answer to "I do not have that", and it is what the
  /// SDK asks for: not-found is a result, not a failure. Throwing here would
  /// tell the host this plugin is broken when it is merely being asked about
  /// something it never had.
  SwayveAlbum? albumByValue(String value) =>
      _firstWhereOrNull(albums, (album) => album.id.value == value);

  /// The artist whose media id has this [value], or `null` if there is none.
  SwayveArtist? artistByValue(String value) =>
      _firstWhereOrNull(artists, (artist) => artist.id.value == value);
}

/// Mints a media id for a fixture row.
///
/// The `<kind>:<id>` shape is this plugin's private business. The host never
/// parses `value` — it round-trips the whole id back to us — so a plugin is
/// free to encode whatever it needs to resolve the item later. What it is not
/// free to do is change the encoding casually: the host persists these ids, so
/// yesterday's library must still resolve tomorrow.
SwayveMediaId _mediaId(String kind, String fixtureId) =>
    SwayveMediaId(examplePluginId, '$kind:$fixtureId');

ExampleCatalogue _buildFixtureCatalogue() {
  final artists = <SwayveArtist>[
    for (final raw in _rawArtists)
      SwayveArtist(
        id: _mediaId('artist', raw.id),
        name: raw.name,
        genres: raw.genres,
        // `extra` is the escape hatch for provider-specific data. The host
        // carries it, persists it and hands it back untouched — it never reads
        // it, because the moment it did it would need to know which plugin
        // wrote it. Use it to save yourself a lookup later; never use it to
        // smuggle in something the host is supposed to act on. Keys are
        // prefixed so two plugins' `extra` maps stay legible side by side, and
        // values must be JSON-encodable because the host may store them.
        extra: {'exampleFixtureId': raw.id},
      ),
  ];

  final artistsByFixtureId = <String, SwayveArtist>{
    for (var i = 0; i < _rawArtists.length; i++) _rawArtists[i].id: artists[i],
  };
  final artistsByName = <String, SwayveArtist>{
    for (final artist in artists) artist.name.toLowerCase(): artist,
  };

  final albums = <SwayveAlbum>[
    for (final raw in _rawAlbums)
      SwayveAlbum(
        id: _mediaId('album', raw.id),
        title: raw.title,
        artists: [_refTo(artistsByFixtureId[raw.artistId]!)],
        year: raw.year,
        trackCount: _rawTracks.where((track) => track.albumId == raw.id).length,
        extra: {'exampleFixtureId': raw.id},
      ),
  ];

  final albumsByFixtureId = <String, SwayveAlbum>{
    for (var i = 0; i < _rawAlbums.length; i++) _rawAlbums[i].id: albums[i],
  };

  final tracks = <SwayveTrack>[
    for (final raw in _rawTracks)
      _normalizeTrack(raw, albumsByFixtureId, artistsByName),
  ];

  return ExampleCatalogue(artists: artists, albums: albums, tracks: tracks);
}

SwayveTrack _normalizeTrack(
  _RawTrack raw,
  Map<String, SwayveAlbum> albumsByFixtureId,
  Map<String, SwayveArtist> artistsByName,
) {
  final album = albumsByFixtureId[raw.albumId];
  return SwayveTrack(
    id: _mediaId('track', raw.id),
    title: raw.title,
    artists: _creditToRefs(raw.credit, artistsByName),
    album:
        album == null ? null : SwayveAlbumRef(title: album.title, id: album.id),
    // Seconds in, `Duration` out. Trivially small, and exactly the sort of
    // conversion that turns into a bug when it is done in three places
    // instead of one.
    duration: Duration(seconds: raw.lengthSeconds),
    trackNumber: raw.trackNumber,
    year: album?.year,
    // Three independent facts, stated truthfully (SDK principle 6). This
    // plugin declares `media.streamable: false` and
    // `media.downloadable: false` in its manifest and registers no
    // `SwayveStreamProvider`, so claiming anything else here would be a lie
    // the host has no way to detect until a user presses play. A plugin may
    // contribute catalogue data without claiming any playback rights, and
    // this is what that looks like.
    availability: SwayveAvailability.none,
    extra: {
      'exampleFixtureId': raw.id,
      'exampleAlbumFixtureId': raw.albumId,
    },
  );
}

/// Splits a one-string artist credit into refs, resolving the ones we know.
///
/// A ref whose `id` is `null` is not a bug: it means "this artist is credited
/// but I cannot take you to a page for them". Inventing an id for Wren Adeyemi
/// would mint an identifier that resolves to nothing, and the host would
/// happily render a link into a dead end. Absent is better than wrong.
List<SwayveArtistRef> _creditToRefs(
  String credit,
  Map<String, SwayveArtist> artistsByName,
) {
  final refs = <SwayveArtistRef>[];
  for (final part in credit.split(' & ')) {
    final name = part.trim();
    if (name.isEmpty) continue;
    final known = artistsByName[name.toLowerCase()];
    refs.add(SwayveArtistRef(name: name, id: known?.id));
  }
  return List<SwayveArtistRef>.unmodifiable(refs);
}

SwayveArtistRef _refTo(SwayveArtist artist) =>
    SwayveArtistRef(name: artist.name, id: artist.id);

T? _firstWhereOrNull<T>(List<T> items, bool Function(T item) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}
