/// A small, focused client for SoundCloud's public, unauthenticated v2 API.
///
/// Owns URL construction, the one non-obvious credential (a `client_id`
/// scraped from SoundCloud's own web bundle — see [clientId]), status
/// interpretation, and JSON decoding. It owns **no transport**: every byte
/// goes through the host-supplied [SwayveHttpClient], so the `network`
/// permission and the manifest's `network.hosts` allowlist are the only way
/// this plugin ever reaches the network. See `errors.dart` for why every
/// consumer of this client wraps its calls in `runGuarded`.
library;

import 'dart:math' as math;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'errors.dart';
import 'json_path.dart';
import 'parsing/playlist_parser.dart';
import 'parsing/track_parser.dart';

/// Thrown when [SoundCloudClient.clientId] cannot find a usable id anywhere
/// on the scraped page.
///
/// Deliberately not a `SwayvePluginException`: `runGuarded` (see
/// `errors.dart`) turns any non-SDK exception into
/// `SwayvePluginUnavailableException` with this as the `cause`, which is
/// exactly the classification a broken scrape deserves — a service condition
/// every provider method shares, not something worth a bespoke exception type
/// in the public surface.
final class SoundCloudClientIdException implements Exception {
  /// Creates the exception with [message].
  const SoundCloudClientIdException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'SoundCloudClientIdException: $message';
}

/// One page of a SoundCloud `collection` response: the raw, unparsed items
/// and the opaque `next_href` that fetches the next page, or `null` at the
/// end.
final class SoundCloudPage {
  /// Creates a page.
  const SoundCloudPage({required this.items, required this.nextHref});

  /// An empty, final page.
  static const SoundCloudPage empty = SoundCloudPage(items: [], nextHref: null);

  /// The raw JSON items on this page, in provider order.
  final List<Object?> items;

  /// SoundCloud's own continuation URL, or `null` when this is the last page.
  final String? nextHref;
}

/// The client every provider in this plugin shares.
final class SoundCloudClient {
  /// Creates a client over [http].
  SoundCloudClient({
    required SwayveHttpClient http,
    this.timeouts = SoundCloudTimeouts.manifest,
  }) : _http = http;

  final SwayveHttpClient _http;

  /// The deadlines this client works to.
  final SoundCloudTimeouts timeouts;

  String? _clientId;
  Future<String>? _clientIdFetch;

  static final RegExp _scriptSrcPattern =
      RegExp('<script[^>]*\\ssrc="([^"]+)"[^>]*>', caseSensitive: false);

  // ---------------------------------------------------------------------
  // client_id acquisition, caching and recovery
  // ---------------------------------------------------------------------

  /// The current `client_id`, scraping and caching one on first use.
  ///
  /// Concurrent callers before the first scrape completes share the same
  /// in-flight fetch rather than each starting their own — a burst of calls
  /// during startup (search plus artwork plus a stream resolution, say)
  /// should cost one page fetch, not several.
  Future<String> clientId({SwayveCancellationToken? cancel}) {
    final String? cached = _clientId;
    if (cached != null) return Future<String>.value(cached);
    final Future<String>? inFlight = _clientIdFetch;
    if (inFlight != null) return inFlight;
    final Future<String> fetch = _scrapeClientId(cancel: cancel);
    _clientIdFetch = fetch;
    return fetch.then(
      (String id) {
        _clientId = id;
        _clientIdFetch = null;
        return id;
      },
      onError: (Object error, StackTrace stackTrace) {
        _clientIdFetch = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }

  /// Drops the cached `client_id`, so the next [clientId] call re-scrapes.
  ///
  /// Called once, internally, when any request answers `401` — see
  /// [_authedGet]. Exposed for tests that want to force a re-scrape without
  /// waiting for a fixture to answer unauthorized.
  void forgetClientId() {
    _clientId = null;
    _clientIdFetch = null;
  }

  Future<String> _scrapeClientId({SwayveCancellationToken? cancel}) async {
    final SwayveHttpResponse pageResponse =
        await _rawGet(kClientIdSourcePage, cancel: cancel);
    if (!pageResponse.isSuccess) {
      throwForStatus(pageResponse, kClientIdSourcePage);
    }
    final List<String> scriptSources = <String>[
      for (final RegExpMatch match
          in _scriptSrcPattern.allMatches(pageResponse.bodyAsString))
        match.group(1)!,
    ];

    // Tried from the end: this is empirically where the app bundle carrying
    // `client_id` sits, and scanning a bounded window from the end recovers
    // from a page that appends an unrelated trailing script (analytics, a
    // consent-management tag) without paying for every script on the page.
    final Iterable<String> candidates =
        scriptSources.reversed.take(kClientIdScriptScanLimit);

    for (final String source in candidates) {
      final Uri? scriptUrl = _resolveScriptUrl(source);
      if (scriptUrl == null || !isAllowedHost(scriptUrl.host)) continue;
      final SwayveHttpResponse scriptResponse =
          await _rawGet(scriptUrl, cancel: cancel);
      if (!scriptResponse.isSuccess) continue;
      final String? id = _extractClientId(scriptResponse.bodyAsString);
      if (id != null && id.isNotEmpty) return id;
    }

    throw const SoundCloudClientIdException(
      'no client_id was found in any script bundle on the scrape page.',
    );
  }

  Uri? _resolveScriptUrl(String source) {
    if (source.startsWith('//')) return Uri.tryParse('https:$source');
    final Uri? direct = Uri.tryParse(source);
    if (direct != null && direct.hasScheme) return direct;
    return direct == null ? null : kClientIdSourcePage.resolveUri(direct);
  }

  String? _extractClientId(String body) =>
      kClientIdPatternColon.firstMatch(body)?.group(1) ??
      kClientIdPatternQuery.firstMatch(body)?.group(1);

  // ---------------------------------------------------------------------
  // low-level request plumbing
  // ---------------------------------------------------------------------

  Future<SwayveHttpResponse> _rawGet(
    Uri url, {
    SwayveCancellationToken? cancel,
  }) {
    if (!isAllowedHost(url.host)) {
      throw SwayvePluginUnsupportedException(
        'SoundCloud will not request $url: ${url.host} is not declared in '
        "the plugin manifest's network.hosts.",
      );
    }
    return _http.get(url, timeout: timeouts.request, cancel: cancel);
  }

  Uri _withParams(Uri base, Map<String, String> params) => base.replace(
        queryParameters: <String, String>{...base.queryParameters, ...params},
      );

  Uri _apiUri(String path, [Map<String, String> params = const <String, String>{}]) =>
      _withParams(Uri.parse('$kApiOrigin$path'), params);

  /// Performs an authenticated GET, retrying **exactly once** with a freshly
  /// scraped `client_id` when the first attempt answers `401` — the scraped
  /// credential can go stale between plugin startup and a request, and a
  /// fresh scrape is the recovery, not a second try with the same one.
  Future<({SwayveHttpResponse response, Uri url})> _authedGet(
    Uri baseUrl, {
    Map<String, String> params = const <String, String>{},
    SwayveCancellationToken? cancel,
  }) async {
    final String id = await clientId(cancel: cancel);
    Uri url = _withParams(baseUrl, <String, String>{...params, 'client_id': id});
    SwayveHttpResponse response = await _rawGet(url, cancel: cancel);
    if (response.statusCode == 401) {
      forgetClientId();
      final String freshId = await clientId(cancel: cancel);
      url = _withParams(baseUrl, <String, String>{...params, 'client_id': freshId});
      response = await _rawGet(url, cancel: cancel);
    }
    return (response: response, url: url);
  }

  Future<Map<String, Object?>> _getJson(
    Uri baseUrl, {
    Map<String, String> params = const <String, String>{},
    SwayveCancellationToken? cancel,
  }) async {
    final result = await _authedGet(baseUrl, params: params, cancel: cancel);
    if (!result.response.isSuccess) throwForStatus(result.response, result.url);
    final Object? body = result.response.bodyAsJson;
    if (body is! Map) {
      malformedResponse(
        'expected a JSON object from ${result.url.host}${result.url.path} '
        'but got ${body.runtimeType}.',
      );
    }
    return mapOf(body);
  }

  /// As [_getJson], but a `404` is `null` rather than an exception — the
  /// right answer for a single-entity lookup where "not found" is a fact,
  /// not a failure.
  Future<Map<String, Object?>?> _getJsonOrNull(
    Uri baseUrl, {
    Map<String, String> params = const <String, String>{},
    SwayveCancellationToken? cancel,
  }) async {
    final result = await _authedGet(baseUrl, params: params, cancel: cancel);
    if (result.response.statusCode == 404) return null;
    if (!result.response.isSuccess) throwForStatus(result.response, result.url);
    final Object? body = result.response.bodyAsJson;
    if (body is! Map) {
      malformedResponse(
        'expected a JSON object from ${result.url.host}${result.url.path} '
        'but got ${body.runtimeType}.',
      );
    }
    return mapOf(body);
  }

  Future<List<Object?>> _getJsonArray(
    Uri baseUrl, {
    Map<String, String> params = const <String, String>{},
    SwayveCancellationToken? cancel,
  }) async {
    final result = await _authedGet(baseUrl, params: params, cancel: cancel);
    if (!result.response.isSuccess) throwForStatus(result.response, result.url);
    final Object? body = result.response.bodyAsJson;
    if (body is! List) {
      malformedResponse(
        'expected a JSON array from ${result.url.host}${result.url.path} but '
        'got ${body.runtimeType}.',
      );
    }
    return body;
  }

  // ---------------------------------------------------------------------
  // pagination
  // ---------------------------------------------------------------------

  Future<SoundCloudPage> _getCollection(
    Uri url, {
    SwayveCancellationToken? cancel,
  }) async {
    final Map<String, Object?> json = await _getJson(url, cancel: cancel);
    return SoundCloudPage(
      items: listAt(json, <Object>['collection']),
      nextHref: stringAt(json, <Object>['next_href']),
    );
  }

  /// Follows an opaque `next_href` cursor previously handed to the host.
  ///
  /// The href is a **complete URL**, captured with the `client_id` that was
  /// current when it was minted — which may have rotated since, so it is
  /// stripped and re-injected fresh rather than trusted. A cursor pointing
  /// somewhere off the manifest's allowlist is a malformed-response
  /// condition, not something to follow blindly.
  Future<SoundCloudPage> _followCursor(
    String cursor, {
    SwayveCancellationToken? cancel,
  }) {
    final Uri? parsed = Uri.tryParse(cursor);
    final Uri target = (parsed != null && isAllowedHost(parsed.host))
        ? parsed
        : malformedResponse(
            'a pagination cursor pointed somewhere this plugin will not '
            'follow: $cursor',
          );
    final Uri stripped = target.replace(
      queryParameters: <String, String>{...target.queryParameters}
        ..remove('client_id'),
    );
    return _getCollection(stripped, cancel: cancel);
  }

  /// The page [cursor] asks for: the first page of [firstPageUrl] when
  /// [cursor] is `null`, otherwise whatever [cursor] itself points at.
  Future<SoundCloudPage> pageFor(
    String? cursor,
    Uri firstPageUrl, {
    SwayveCancellationToken? cancel,
  }) =>
      cursor == null
          ? _getCollection(firstPageUrl, cancel: cancel)
          : _followCursor(cursor, cancel: cancel);

  // ---------------------------------------------------------------------
  // public API surface
  // ---------------------------------------------------------------------

  /// Searches one SoundCloud kind (`tracks`, `albums`, `playlists`, `users`)
  /// for [query].
  Future<SoundCloudPage> search(
    String kindPath,
    String query, {
    required int limit,
    String? cursor,
    SwayveCancellationToken? cancel,
  }) =>
      pageFor(
        cursor,
        _apiUri('/search/$kindPath', <String, String>{
          'q': query,
          'limit': '$limit',
        }),
        cancel: cancel,
      );

  /// A single track by [id], or `null` when it no longer resolves.
  Future<Map<String, Object?>?> track(
    int id, {
    SwayveCancellationToken? cancel,
  }) =>
      _getJsonOrNull(_apiUri('/tracks/$id'), cancel: cancel);

  /// Every track object SoundCloud returns for [ids], batched at
  /// [kTrackBatchSize] ids per request.
  ///
  /// An id SoundCloud does not resolve is simply absent from the result
  /// rather than reported — the caller (playlist hydration) already treats a
  /// missing id as "could not hydrate this one."
  Future<List<Map<String, Object?>>> tracksByIds(
    List<int> ids, {
    SwayveCancellationToken? cancel,
  }) async {
    if (ids.isEmpty) return const <Map<String, Object?>>[];
    final List<Map<String, Object?>> result = <Map<String, Object?>>[];
    for (int start = 0; start < ids.length; start += kTrackBatchSize) {
      final List<int> batch =
          ids.sublist(start, math.min(start + kTrackBatchSize, ids.length));
      final List<Object?> array = await _getJsonArray(
        _apiUri('/tracks', <String, String>{'ids': batch.join(',')}),
        cancel: cancel,
      );
      for (final Object? item in array) {
        final Map<String, Object?> json = mapOf(item);
        if (json.isNotEmpty) result.add(json);
      }
    }
    return result;
  }

  /// A single playlist (album or plain playlist — see `SoundCloudIds`) by
  /// [id], or `null` when it no longer resolves. Requests the `full`
  /// representation, which hydrates every track up to SoundCloud's own size
  /// threshold; see [hydratePlaylistTracks] for what happens above it.
  Future<Map<String, Object?>?> playlist(
    int id, {
    SwayveCancellationToken? cancel,
  }) =>
      _getJsonOrNull(
        _apiUri('/playlists/$id', <String, String>{'representation': 'full'}),
        cancel: cancel,
      );

  /// A single user by [id], or `null` when it no longer resolves.
  Future<Map<String, Object?>?> user(
    int id, {
    SwayveCancellationToken? cancel,
  }) =>
      _getJsonOrNull(_apiUri('/users/$id'), cancel: cancel);

  /// One page of SoundCloud's charts — the feed behind `catalog.tracks()`.
  Future<SoundCloudPage> chartTracks({
    required SoundCloudChartKind kind,
    String genre = kAllMusicGenre,
    String region = kGlobalRegionValue,
    String? cursor,
    SwayveCancellationToken? cancel,
  }) {
    final Map<String, String> params = <String, String>{
      'kind': kind.wireName,
      'genre': genre,
    };
    if (region != kGlobalRegionValue && region.isNotEmpty) {
      params['region'] = region;
    }
    return pageFor(cursor, _apiUri('/charts', params), cancel: cancel);
  }

  /// One page of SoundCloud's playlist discovery shelves — the feed behind
  /// `catalog.albums()` (filtered to `is_album: true`) and
  /// `SoundCloudPlaylistProvider.playlists()` (unfiltered).
  ///
  /// This endpoint's exact response envelope has not been exercised against
  /// live traffic (see the plugin README's "fixture-verified vs.
  /// live-validated" section), so both plausible shapes are handled: a flat
  /// `collection`, and a `sections[].items`/`sections[].playlists` shelf
  /// layout. Neither matching is a malformed response — just an empty page,
  /// the same "nothing to browse here, not a failure" answer this provider
  /// gives when SoundCloud genuinely has nothing to offer.
  Future<SoundCloudPage> playlistDiscovery({
    String tag = kDefaultDiscoveryTag,
    String? cursor,
    SwayveCancellationToken? cancel,
  }) async {
    if (cursor != null) return _followCursor(cursor, cancel: cancel);
    final Map<String, Object?> json = await _getJson(
      _apiUri('/playlists/discovery', <String, String>{'tag': tag}),
      cancel: cancel,
    );
    final List<Object?> direct = listAt(json, <Object>['collection']);
    if (direct.isNotEmpty) {
      return SoundCloudPage(
        items: direct,
        nextHref: stringAt(json, <Object>['next_href']),
      );
    }
    final List<Object?> flattened = <Object?>[];
    for (final Object? section in listAt(json, <Object>['sections'])) {
      final Map<String, Object?> sectionMap = mapOf(section);
      final List<Object?> items = listAt(sectionMap, <Object>['items']);
      flattened.addAll(
        items.isNotEmpty ? items : listAt(sectionMap, <Object>['playlists']),
      );
    }
    return SoundCloudPage(items: flattened, nextHref: null);
  }

  /// Resolves one transcoding's own `url` (from `media.transcodings[].url`
  /// on a track) to the final, playable CDN address.
  Future<Uri> resolveMediaUrl(
    Uri transcodingUrl, {
    SwayveCancellationToken? cancel,
  }) async {
    if (!isAllowedHost(transcodingUrl.host)) {
      throw SwayvePluginUnsupportedException(
        'SoundCloud will not resolve a transcoding url on '
        '${transcodingUrl.host}: not declared in the plugin manifest.',
      );
    }
    final Map<String, Object?> json =
        await _getJson(transcodingUrl, cancel: cancel);
    final String? urlString = stringAt(json, <Object>['url']);
    final Uri? resolved = urlString == null ? null : Uri.tryParse(urlString);
    return resolved ??
        malformedResponse('a media resolution response had no usable url.');
  }

  /// Resolves [envelope]'s track list to real [SwayveTrack]s, fetching any
  /// stub entries in bounded batches of [kTrackBatchSize] via [tracksByIds].
  ///
  /// Bounded by [kMaxHydrationBatches]: hitting it means something is wrong
  /// (a batch that never shrinks the stub count), not that somebody owns an
  /// unusually long playlist. A batch that throws is caught and skipped —
  /// its stubs are simply absent from the result, per
  /// [spliceHydratedTracks]'s "keep what was gathered" rule — rather than
  /// failing the whole lookup over one bad batch.
  Future<List<SwayveTrack>> hydratePlaylistTracks(
    ParsedPlaylistEnvelope envelope, {
    SwayveCancellationToken? cancel,
  }) async {
    final List<int> stubs = stubIdsIn(envelope.rawTracks);
    if (stubs.isEmpty) {
      return spliceHydratedTracks(envelope.rawTracks, const <int, SwayveTrack>{});
    }

    final Map<int, SwayveTrack> hydrated = <int, SwayveTrack>{};
    int batches = 0;
    for (int start = 0;
        start < stubs.length && batches < kMaxHydrationBatches;
        start += kTrackBatchSize, batches++) {
      final List<int> batch =
          stubs.sublist(start, math.min(start + kTrackBatchSize, stubs.length));
      try {
        final List<Map<String, Object?>> fetched =
            await tracksByIds(batch, cancel: cancel);
        for (final Map<String, Object?> json in fetched) {
          final SwayveTrack? track = parseTrack(json);
          final int? id = intAt(json, <Object>['id']);
          if (track != null && id != null) hydrated[id] = track;
        }
      } on SwayvePluginException {
        continue;
      }
    }
    return spliceHydratedTracks(envelope.rawTracks, hydrated);
  }
}
