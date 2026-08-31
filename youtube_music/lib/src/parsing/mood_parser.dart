/// The parser for YouTube Music's mood and genre directory.
///
/// `FEmusic_moods_and_genres` is the one browse in this plugin that returns
/// **no models at all**, and that is a fact about the payload rather than a
/// gap in `item_parser.dart`. Measured against the live endpoint: it answers
/// with two `gridRenderer`s of `musicNavigationButtonRenderer` chips — "Moods
/// & moments" and "Genres" — and every single chip carries the *same* browse
/// id, `FEmusic_moods_and_genres_category`. What tells "Chill" apart from
/// "Workout" is an opaque `params` blob and nothing else.
///
/// So a chip is not a playlist and must not be minted as one: a
/// `SwayvePlaylist` whose id is the same string for every row would collide
/// with every other row the moment a host put them in a map. A chip is a
/// *second request*, and that is all this file models.
library;

import '../json_path.dart';

/// One mood or genre chip: a label and the params that open it.
final class MoodChip {
  /// Creates a chip.
  const MoodChip({required this.title, required this.params});

  /// The chip's label, already localized by the service.
  final String title;

  /// The opaque blob that selects this category on a
  /// `FEmusic_moods_and_genres_category` browse. Never empty.
  final String params;

  @override
  String toString() => 'MoodChip($title)';
}

/// Every chip in a `FEmusic_moods_and_genres` response, in payload order.
///
/// Returns an empty list rather than throwing for a body that carries none:
/// the directory is a convenience surface, and a shape change there should
/// cost the user a shelf rather than an error.
List<MoodChip> parseMoodChips(Map<String, Object?> body) {
  final List<MoodChip> chips = <MoodChip>[];
  for (final Object? section in _sections(body)) {
    for (final Object? item in listAt(section, const <Object>[
      'gridRenderer',
      'items',
    ])) {
      final MoodChip? chip = _chipOf(item);
      if (chip != null) chips.add(chip);
    }
  }
  return List<MoodChip>.unmodifiable(chips);
}

MoodChip? _chipOf(Object? item) {
  final Map<String, Object?> button = mapAt(item, const <Object>[
    'musicNavigationButtonRenderer',
  ]);
  if (button.isEmpty) return null;
  final String? title = runsTextAt(button, const <Object>[
    'buttonText',
    'runs',
  ]);
  // `clickCommand` on this renderer, not the `navigationEndpoint` every other
  // renderer in this payload uses. Both are probed so that a rename of one
  // costs nothing.
  final String? params = stringAt(button, const <Object>[
        'clickCommand',
        'browseEndpoint',
        'params',
      ]) ??
      stringAt(button, const <Object>[
        'navigationEndpoint',
        'browseEndpoint',
        'params',
      ]);
  if (title == null || title.trim().isEmpty) return null;
  if (params == null || params.isEmpty) return null;
  return MoodChip(title: title.trim(), params: params);
}

List<Object?> _sections(Map<String, Object?> body) {
  final List<Object?> tabbed = <Object?>[
    for (final Object? tab in listAt(body, const <Object>[
      'contents',
      'singleColumnBrowseResultsRenderer',
      'tabs',
    ]))
      ...listAt(tab, const <Object>[
        'tabRenderer',
        'content',
        'sectionListRenderer',
        'contents',
      ]),
  ];
  if (tabbed.isNotEmpty) return tabbed;
  return listAt(body, const <Object>[
    'contents',
    'sectionListRenderer',
    'contents',
  ]);
}
