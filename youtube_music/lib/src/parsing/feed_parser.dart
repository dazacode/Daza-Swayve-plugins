import '../json_path.dart';
import 'item_parser.dart';

/// Everything one InnerTube list response yielded.
final class ParsedFeed {
  /// Creates a parsed feed.
  const ParsedFeed({required this.items, this.cursor});

  /// The models found, partitioned by kind.
  final ItemCollector items;

  /// The continuation token for the next page, or `null` at the end.
  final String? cursor;
}

/// Parses a search or browse response into models and a cursor.
///
/// Search and browse differ only in how they wrap their section list — a
/// `tabbedSearchResultsRenderer` versus a `singleColumnBrowseResultsRenderer`
/// — and continuations flatten both into the same shape. Handling all of them
/// in one place is what lets the search provider and the catalog provider
/// share a single, tested notion of "a shelf of items".
///
/// [what] names the request in a failure message. It is used only when the
/// body carries no recognisable section list at all, which is the point where
/// the parser stops probing and reports
/// `SwayvePluginMalformedResponseException` — everything shallower than that
/// degrades to a skipped item instead.
ParsedFeed parseFeed(Map<String, Object?> body, {required String what}) {
  final ParsedFeed? feed = tryParseFeed(body);
  if (feed == null) {
    malformedResponse(
      'the $what response carried no recognisable content section.',
    );
  }
  return feed;
}

/// Parses a list response, or returns `null` when the body has no section
/// list at all.
///
/// Used where a listing is a bonus rather than the point of the request — an
/// album browse is still a valid album when its track shelf is missing, and
/// failing the whole lookup over it would turn a thin response into an
/// outage.
ParsedFeed? tryParseFeed(Map<String, Object?> body) {
  final List<Object?>? sections = _sections(body);
  if (sections == null) return null;
  final ItemCollector items = ItemCollector();
  String? cursor;
  for (final Object? section in sections) {
    final Map<String, Object?>? shelf = shelfOf(section);
    if (shelf == null) continue;
    items.addAll(shelfItems(shelf));
    cursor ??= continuationOf(shelf);
  }
  cursor ??= continuationOf(body);
  return ParsedFeed(items: items, cursor: cursor);
}

/// The section list of [body], or `null` when it has none.
///
/// The order matters: a continuation response is checked first because it also
/// has a `contents` key, just one holding a bare shelf rather than a tab
/// structure.
List<Object?>? _sections(Map<String, Object?> body) {
  final Map<String, Object?> continuation = mapAt(body, const <Object>[
    'continuationContents',
  ]);
  if (continuation.isNotEmpty) {
    return <Object?>[
      for (final MapEntry<String, Object?> entry in continuation.entries)
        <String, Object?>{_continuationShelfKey(entry.key): entry.value},
    ];
  }

  for (final List<Object> tabsPath in const <List<Object>>[
    <Object>['contents', 'tabbedSearchResultsRenderer', 'tabs'],
    <Object>['contents', 'singleColumnBrowseResultsRenderer', 'tabs'],
  ]) {
    final List<Object?> tabs = listAt(body, tabsPath);
    if (tabs.isEmpty) continue;
    final List<Object?> sections = <Object?>[];
    for (final Object? tab in tabs) {
      sections.addAll(
        listAt(tab, const <Object>[
          'tabRenderer',
          'content',
          'sectionListRenderer',
          'contents',
        ]),
      );
    }
    if (sections.isNotEmpty) return sections;
  }

  final List<Object?> flat = listAt(body, const <Object>[
    'contents',
    'sectionListRenderer',
    'contents',
  ]);
  if (flat.isNotEmpty) return flat;

  return null;
}

/// Maps a `*Continuation` key back to the shelf key [shelfOf] recognises.
String _continuationShelfKey(String key) => switch (key) {
      'musicShelfContinuation' => 'musicShelfRenderer',
      'musicPlaylistShelfContinuation' => 'musicPlaylistShelfRenderer',
      'musicCarouselShelfContinuation' => 'musicCarouselShelfRenderer',
      'gridContinuation' => 'gridRenderer',
      'sectionListContinuation' => 'sectionListRenderer',
      _ => key,
    };

/// The known shelf renderers, in the order they are probed.
const List<String> _shelfKeys = <String>[
  'musicShelfRenderer',
  'musicPlaylistShelfRenderer',
  'musicCarouselShelfRenderer',
  'gridRenderer',
];

/// The shelf inside [section], or `null` when [section] is not one.
///
/// A `sectionListRenderer` nested inside a section (which is how a
/// continuation of a browse feed arrives) is unwrapped one level so the caller
/// still sees shelves.
Map<String, Object?>? shelfOf(Object? section) {
  final Map<String, Object?> map = mapOf(section);
  for (final String key in _shelfKeys) {
    final Object? shelf = map[key];
    if (shelf != null) return mapOf(shelf);
  }
  final Object? nested = map['sectionListRenderer'];
  if (nested != null) {
    for (final Object? inner in listAt(nested, const <Object>['contents'])) {
      final Map<String, Object?>? found = shelfOf(inner);
      if (found != null) return found;
    }
  }
  return null;
}

/// The item array of [shelf]. A grid calls it `items`; everything else calls
/// it `contents`.
List<Object?> shelfItems(Map<String, Object?> shelf) {
  final List<Object?> contents = listOf(shelf['contents']);
  if (contents.isNotEmpty) return contents;
  return listOf(shelf['items']);
}

/// The continuation token carried by [node], or `null`.
///
/// Both the older `continuations` array and the newer inline
/// `continuationItemRenderer` are read, because YouTube Music has been
/// migrating between them for years and both still appear.
String? continuationOf(Object? node) {
  for (final Object? entry in listAt(node, const <Object>['continuations'])) {
    for (final String key in const <String>[
      'nextContinuationData',
      'reloadContinuationData',
      'nextRadioContinuationData',
    ]) {
      final String? token = stringAt(entry, <Object>[key, 'continuation']);
      if (token != null && token.isNotEmpty) return token;
    }
  }
  for (final Object? entry in listOf(mapOf(node)['contents'])) {
    final String? token = stringAt(entry, const <Object>[
      'continuationItemRenderer',
      'continuationEndpoint',
      'continuationCommand',
      'token',
    ]);
    if (token != null && token.isNotEmpty) return token;
  }
  return null;
}
