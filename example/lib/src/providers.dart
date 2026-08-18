/// The two provider implementations this plugin's capabilities promise.
///
/// One interface per capability is not an accident of the SDK's design, it is
/// the point of it: the host discovers what a plugin can do by which providers
/// it registered, so a plugin implements exactly the surfaces it declared and
/// nothing else. There is no giant `Plugin` interface with twenty methods,
/// eighteen of which throw `UnimplementedError`.
///
/// Three rules apply to every method in this file, and to every provider
/// method you will ever write:
///
/// * **Return a result, or throw a `SwayvePluginException`.** Never anything
///   else. The host isolates a raw throw too, but it cannot interpret it: an
///   unknown error can only be shown as a generic "temporarily unavailable",
///   which is a worse experience than the accurate message the sealed
///   hierarchy would have let it show.
/// * **Not-found is a value.** An empty result or `null`, never an exception.
///   "I searched and there was nothing" and "I could not search" are different
///   facts and the host renders them differently.
/// * **Honour the deadline and the token.** Check cancellation before
///   expensive work and after every await; finish inside
///   `SwayveTimeouts.operation` or say you did not.
library;

import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'catalogue.dart';

/// Free-text search over the fixture catalogue. Capability: `search`.
final class ExampleSearchProvider implements SwayveSearchProvider {
  /// Creates a provider serving [catalogue].
  ExampleSearchProvider(this._catalogue);

  final ExampleCatalogue _catalogue;

  @override
  Future<SwayveSearchResult> search(
    SwayveSearchQuery query, {
    SwayveCancellationToken? cancel,
  }) =>
      _withinOperationDeadline(() async {
        // Check before doing anything. The host may already have moved on —
        // the user typed another character, or left the screen — and the
        // cheapest possible response to that is to not start.
        cancel?.throwIfCancelled();

        final needle = query.text.trim().toLowerCase();
        // An empty query is not an error, and it is not "everything" either.
        // `SwayveSearchResult.empty` says "I searched, there was nothing",
        // which is exactly true.
        if (needle.isEmpty) return SwayveSearchResult.empty;

        // `query.limit` is a ceiling *per kind*, not a total, so each of these
        // gets its own budget. `query.kinds` is honoured rather than ignored:
        // returning albums to a caller that asked only for tracks wastes the
        // user's bandwidth and the host's rendering, and the host is entitled
        // to assume a provider means what it sends.
        final tracks = _collect(
          source: _catalogue.tracks,
          wanted: query.kinds.contains(SwayveSearchKind.track),
          limit: query.limit,
          cancel: cancel,
          // Matching on the credit as well as the title is what makes
          // searching for an artist's name turn up their songs. It is also
          // this plugin's own business: the SDK deliberately hands over
          // `query.text` unprocessed, because a provider knows its own
          // service's query semantics and the host does not.
          matches: (track) =>
              _contains(needle, [track.title, track.artistsLabel]),
        );

        final albums = _collect(
          source: _catalogue.albums,
          wanted: query.kinds.contains(SwayveSearchKind.album),
          limit: query.limit,
          cancel: cancel,
          matches: (album) => _contains(needle, [
            album.title,
            for (final artist in album.artists) artist.name,
          ]),
        );

        final artists = _collect(
          source: _catalogue.artists,
          wanted: query.kinds.contains(SwayveSearchKind.artist),
          limit: query.limit,
          cancel: cancel,
          matches: (artist) =>
              _contains(needle, [artist.name, ...artist.genres]),
        );

        return SwayveSearchResult(
          tracks: tracks,
          albums: albums,
          artists: artists,
          // No playlists, ever: this plugin has none and does not declare the
          // `playlist_read` capability. An empty list is the correct answer to
          // a kind we cannot serve — a provider must not throw
          // `SwayvePluginUnsupportedException` for one requested kind out of
          // four when it can perfectly well answer the rest.
          playlists: const [],
          // The whole catalogue fits in one response, so there is nothing to
          // continue. A `null` cursor is how a provider says "that was all of
          // it"; returning a cursor here would make the host ask for a second
          // page that could only ever come back empty.
          cursor: null,
          // `partial: true` would mean "I truncated or degraded this" — a
          // timed-out sub-request, a service that answered for tracks but not
          // albums. Nothing was degraded here.
          partial: false,
        );
      });

  List<T> _collect<T>({
    required List<T> source,
    required bool wanted,
    required int limit,
    required bool Function(T item) matches,
    SwayveCancellationToken? cancel,
  }) {
    if (!wanted || limit <= 0) return const [];
    final found = <T>[];
    for (final item in source) {
      // Inside the loop, not merely before it. A cooperative provider stops as
      // soon as it is asked to; a provider that only checks at the start will
      // happily finish a two-second scan the host stopped caring about after
      // fifty milliseconds. This loop is short, but the habit is what matters
      // — in a real plugin this is where a page-by-page crawl would be.
      cancel?.throwIfCancelled();
      if (found.length >= limit) break;
      if (matches(item)) found.add(item);
    }
    return List<T>.unmodifiable(found);
  }
}

/// Browsing the fixture catalogue. Capability: `catalog`.
final class ExampleCatalogProvider implements SwayveCatalogProvider {
  /// Creates a provider serving [catalogue].
  ExampleCatalogProvider(this._catalogue);

  final ExampleCatalogue _catalogue;

  @override
  Future<SwayvePage<SwayveAlbum>> albums(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      _withinOperationDeadline(() async {
        cancel?.throwIfCancelled();
        return _page(
          _ordered(_catalogue.albums, request.sort, (album) => album.title),
          request,
        );
      });

  @override
  Future<SwayvePage<SwayveArtist>> artists(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      _withinOperationDeadline(() async {
        cancel?.throwIfCancelled();
        return _page(
          _ordered(_catalogue.artists, request.sort, (artist) => artist.name),
          request,
        );
      });

  @override
  Future<SwayvePage<SwayveTrack>> tracks(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      _withinOperationDeadline(() async {
        cancel?.throwIfCancelled();
        return _page(
          _ordered(_catalogue.tracks, request.sort, (track) => track.title),
          request,
        );
      });

  @override
  Future<SwayveAlbum?> album(
    SwayveMediaId id, {
    SwayveCancellationToken? cancel,
  }) =>
      _withinOperationDeadline(() async {
        cancel?.throwIfCancelled();
        // An id another plugin minted is not ours to answer for. The host
        // routes by `pluginId` and should never send us one, but a provider
        // that trusts its input is a provider that returns the wrong album the
        // day the routing changes.
        if (id.pluginId != examplePluginId) return null;
        // And a lookup that legitimately misses — an id we minted for
        // something that is no longer in the catalogue, or a hand-typed one
        // that never existed — is `null`. Not an exception. The host's library
        // is full of ids it saved months ago, and some of them will have gone
        // away; that is an ordinary Tuesday, not a plugin failure.
        return _catalogue.albumByValue(id.value);
      });

  @override
  Future<SwayveArtist?> artist(
    SwayveMediaId id, {
    SwayveCancellationToken? cancel,
  }) =>
      _withinOperationDeadline(() async {
        cancel?.throwIfCancelled();
        if (id.pluginId != examplePluginId) return null;
        return _catalogue.artistByValue(id.value);
      });
}

/// Applies `SwayveTimeouts.operation` to a provider call.
///
/// Every provider method must complete, throw a `SwayvePluginException`, or
/// honour cancellation inside that budget. The host enforces its own hard
/// deadline regardless — but a breach the *host* catches is reported as
/// `SwayvePluginUnavailableException`, which tells a user their source is
/// down. A plugin that notices its own overrun and says
/// `SwayvePluginTimeoutException` is telling the truth about a slow call
/// instead, and the difference shows up in what Swayve puts on screen.
///
/// Being honest about this file: for a catalogue compiled into the binary the
/// timeout can never fire. It is here because it is the shape every real
/// plugin needs, and because a reader copying this file as a starting point
/// should find the deadline already wired up rather than discover later that
/// it was never there.
Future<T> _withinOperationDeadline<T>(Future<T> Function() work) async {
  try {
    return await work().timeout(SwayveTimeouts.operation);
  } on TimeoutException catch (error) {
    throw SwayvePluginTimeoutException(
      'The example plugin did not finish within its operation budget.',
      limit: SwayveTimeouts.operation,
      cause: error,
    );
  }
}

/// Returns one page of [items] plus the cursor that fetches the next.
///
/// Paging is cursor-based rather than offset-based across the whole SDK, so
/// this plugin mints a cursor too even though its data would fit in a single
/// page. The cursor is an opaque string to everyone but this plugin: it
/// happens to be an index, and nothing outside this file may depend on that.
SwayvePage<T> _page<T>(List<T> items, SwayveBrowseRequest request) {
  final start = _decodeCursor(request.cursor);
  // A limit of zero would produce a page with no items and a cursor pointing
  // at the same place — a pager that never terminates. Clamping is how this
  // provider guarantees the loop in `test/catalog_test.dart` finishes.
  final limit = request.limit < 1 ? 1 : request.limit;
  if (start >= items.length) {
    // Past the end: an empty final page, and no cursor. `hasMore` is defined
    // purely by the presence of a cursor, so returning `null` here is what
    // stops the host asking again.
    return SwayvePage<T>(items: <T>[]);
  }
  final end = start + limit > items.length ? items.length : start + limit;
  return SwayvePage<T>(
    items: List<T>.unmodifiable(items.sublist(start, end)),
    cursor: end < items.length ? '$end' : null,
  );
}

int _decodeCursor(String? cursor) {
  if (cursor == null) return 0;
  final start = int.tryParse(cursor);
  if (start == null || start < 0) {
    // This cursor is a value we minted and the host echoed back. If it comes
    // back as something we could not have produced, the exchange is broken,
    // and the one thing a provider must not do is guess — silently starting
    // from zero would hand the caller page one while it believed it was
    // reading page four, and it would never find out.
    throw SwayvePluginMalformedResponseException(
      'Cursor "$cursor" was not minted by this plugin.',
    );
  }
  return start;
}

/// Applies [sort] when this provider can, and ignores it otherwise.
///
/// Ordering is a hint, not a contract: a provider that cannot sort the way it
/// was asked returns its natural order rather than failing. Failing a browse
/// because the caller preferred alphabetical would be a worse outcome for the
/// user than a list in the wrong order.
List<T> _ordered<T>(
  List<T> items,
  SwayveSortOrder? sort,
  String Function(T item) label,
) {
  if (sort != SwayveSortOrder.alphabetical) return items;
  final sorted = List<T>.of(items);
  sorted.sort(
    (a, b) => label(a).toLowerCase().compareTo(label(b).toLowerCase()),
  );
  return sorted;
}

bool _contains(String needle, List<String> haystack) {
  for (final field in haystack) {
    if (field.toLowerCase().contains(needle)) return true;
  }
  return false;
}
