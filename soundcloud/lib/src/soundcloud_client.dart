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
import 'ids.dart';
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
    Map<String, String>? headers,
    SwayveCancellationToken? cancel,
  }) {
    if (!isAllowedHost(url.host)) {
      throw SwayvePluginUnsupportedException(
        'SoundCloud will not request $url: ${url.host} is not declared in '
        "the plugin manifest's network.hosts.",
      );
    }
    return _http.get(
      url,
      headers: headers,
      timeout: timeouts.request,
      cancel: cancel,
    );
  }

  Uri _withParams(Uri base, Map<String, String> params) => base.replace(
        queryParameters: <String, String>{...base.queryParameters, ...params},
      );

  Uri _apiUri(
    String path, [
    Map<String, String> params = const <String, String>{},
  ]) =>
      _withParams(Uri.parse('$kApiOrigin$path'), params);

  /// Performs an authenticated GET, retrying **exactly once** with a freshly
  /// scraped `client_id` when the first attempt answers `401` — the scraped
  /// credential can go stale between plugin startup and a request, and a
  /// fresh scrape is the recovery, not a second try with the same one.
  ///
  /// [headers] is additive and optional — see [me] and [userLikes] for the
  /// one caller that passes a `cookie` header here. Every existing call site
  /// passes nothing and gets exactly the anonymous request this client has
  /// always sent, unchanged. Carried through the 401 retry unaltered: a
  /// cookie the retry needs is the same cookie the first attempt needed.
  Future<({SwayveHttpResponse response, Uri url})> _authedGet(
    Uri baseUrl, {
    Map<String, String> params = const <String, String>{},
    Map<String, String>? headers,
    SwayveCancellationToken? cancel,
  }) async {
    final String id = await clientId(cancel: cancel);
    Uri url =
        _withParams(baseUrl, <String, String>{...params, 'client_id': id});
    SwayveHttpResponse response =
        await _rawGet(url, headers: headers, cancel: cancel);
    if (response.statusCode == 401) {
      forgetClientId();
      final String freshId = await clientId(cancel: cancel);
      url = _withParams(
        baseUrl,
        <String, String>{...params, 'client_id': freshId},
      );
      response = await _rawGet(url, headers: headers, cancel: cancel);
    }
    return (response: response, url: url);
  }

  Future<Map<String, Object?>> _getJson(
    Uri baseUrl, {
    Map<String, String> params = const <String, String>{},
    Map<String, String>? headers,
    SwayveCancellationToken? cancel,
  }) async {
    final result = await _authedGet(
      baseUrl,
      params: params,
      headers: headers,
      cancel: cancel,
    );
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
    Map<String, String>? headers,
    SwayveCancellationToken? cancel,
  }) async {
    final result = await _authedGet(
      baseUrl,
      params: params,
      headers: headers,
      cancel: cancel,
    );
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
    Map<String, String>? headers,
    SwayveCancellationToken? cancel,
  }) async {
    final Map<String, Object?> json =
        await _getJson(url, headers: headers, cancel: cancel);
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
  ///
  /// [headers] is carried through unchanged, same as [_getCollection] — a
  /// cookie an authenticated first page needed is the same cookie every later
  /// page of that same listing needs.
  Future<SoundCloudPage> _followCursor(
    String cursor, {
    Map<String, String>? headers,
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
    return _getCollection(stripped, headers: headers, cancel: cancel);
  }

  /// The page [cursor] asks for: the first page of [firstPageUrl] when
  /// [cursor] is `null`, otherwise whatever [cursor] itself points at.
  Future<SoundCloudPage> pageFor(
    String? cursor,
    Uri firstPageUrl, {
    Map<String, String>? headers,
    SwayveCancellationToken? cancel,
  }) =>
      cursor == null
          ? _getCollection(firstPageUrl, headers: headers, cancel: cancel)
          : _followCursor(cursor, headers: headers, cancel: cancel);

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
  ///
  /// `/featured_tracks/<bucket>/<genre>`, not `/charts` — see the class
  /// comment on [SoundCloudChartKind] for why. [genre] is a path segment, not
  /// escaped further here: every genre slug SoundCloud actually documents is
  /// already URL-safe, and [SoundCloudChartKind.pathSegment] carries its own
  /// escaping for the one bucket name that needs it.
  Future<SoundCloudPage> chartTracks({
    required SoundCloudChartKind kind,
    String genre = kAllMusicGenre,
    String region = kGlobalRegionValue,
    String? cursor,
    SwayveCancellationToken? cancel,
  }) {
    final Map<String, String> params = <String, String>{};
    if (region != kGlobalRegionValue && region.isNotEmpty) {
      params['region'] = region;
    }
    return pageFor(
      cursor,
      _apiUri('/featured_tracks/${kind.pathSegment}/$genre', params),
      cancel: cancel,
    );
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

  /// One page of [id]'s liked tracks (and liked playlists, unfiltered here)
  /// — `/users/{id}/likes`.
  ///
  /// Anonymous, always — this is the scraped `api-v2` surface, used only for
  /// a *public* profile's likes (`SoundCloudArtistActivityProvider`). The
  /// signed-in user's own likes go through [officialMyLikedTracks] instead,
  /// against the official API with a real OAuth token — see that method's
  /// doc comment for why a plain public fetch by id is not simply reused
  /// unauthenticated for the signed-in user's own shelf.
  ///
  /// Confirmed live: each item wraps either `{"track": {...}}` or
  /// `{"playlist": {...}}` alongside `created_at`/`kind: "like"`, the same
  /// `"track"` wrapper key [unwrapChartItem] already handles — no bespoke
  /// unwrapping needed. Filtering the mixed feed down to tracks only is
  /// `SoundCloudArtistActivityProvider`'s job, not this client's.
  Future<SoundCloudPage> userLikes(
    int id, {
    String? cursor,
    SwayveCancellationToken? cancel,
  }) =>
      pageFor(cursor, _apiUri('/users/$id/likes'), cancel: cancel);

  // ---------------------------------------------------------------------
  // official OAuth API — signed-in requests only, never client_id
  // ---------------------------------------------------------------------
  //
  // Everything above this point talks to `api-v2.soundcloud.com`
  // anonymously, with the scraped `client_id` this file exists to manage.
  // The two methods below are a different surface entirely:
  // `api.soundcloud.com`, the officially documented API, authenticated with
  // a real OAuth `access_token` a signed-in user obtained through
  // `SoundCloudAuthProvider`'s authorization-code flow — no `client_id`
  // query parameter, no scraping, no anonymous fallback. See
  // `README.md`'s "Signing in" section for why the anonymous surface cannot
  // answer "my own liked tracks" at all, and why this plugin talks to two
  // different SoundCloud API generations rather than one.
  //
  // **Not exercised against a real signed-in session as part of this
  // change** — the authorization-code exchange that produces a real
  // `access_token` needs an interactive browser consent step this plugin's
  // own test suite cannot simulate; only a real device run can complete it.
  // The header format (`Authorization: OAuth <token>`) and both endpoint
  // shapes below are taken directly from SoundCloud's own developers guide
  // and from `soundcrowd-plugin-soundcloud`/`SqueezeCloud`, two independent,
  // actively-used open-source clients that implement this exact flow
  // against this exact host.

  Future<SwayveHttpResponse> _officialGet(
    String path, {
    required String accessToken,
    Map<String, String> params = const <String, String>{},
    SwayveCancellationToken? cancel,
  }) {
    final Uri url = Uri.parse('$kOAuthApiOrigin$path').replace(
      queryParameters: <String, String>{
        ...Uri.parse('$kOAuthApiOrigin$path').queryParameters,
        ...params,
      },
    );
    return _rawGet(
      url,
      headers: <String, String>{'authorization': 'OAuth $accessToken'},
      cancel: cancel,
    );
  }

  /// The signed-in user behind [accessToken] — the official API's `/me`.
  ///
  /// `null` for a token SoundCloud does not (or no longer) recognise
  /// (`401`/`403`) — the caller's cue to attempt a refresh, or fall back to
  /// asking for a fresh sign-in when refreshing has already been tried. See
  /// `providers/auth_provider.dart`.
  Future<Map<String, Object?>?> officialMe({
    required String accessToken,
    SwayveCancellationToken? cancel,
  }) async {
    final SwayveHttpResponse response = await _officialGet(
      '/me',
      accessToken: accessToken,
      cancel: cancel,
    );
    if (response.statusCode == 401 || response.statusCode == 403) return null;
    if (!response.isSuccess) {
      throwForStatus(response, Uri.parse('$kOAuthApiOrigin/me'));
    }
    final Object? body = response.bodyAsJson;
    if (body is! Map) {
      malformedResponse(
        'expected a JSON object from $kOAuthApiOrigin/me but got '
        '${body.runtimeType}.',
      );
    }
    return mapOf(body);
  }

  /// One page of the signed-in user's own liked tracks — the official API's
  /// `/me/likes/tracks`. Needs no id of its own to look up first: `/me`
  /// already means "whoever this `access_token` belongs to," which is the
  /// whole reason this plugin talks to the official API for this one thing
  /// rather than reusing [userLikes] with a resolved numeric id — this
  /// endpoint simply does not exist on the anonymous `api-v2` surface at
  /// all.
  ///
  /// [cursor] is `next_href`, exactly as [userLikes] and the rest of this
  /// client already page — but a *complete URL* on `api.soundcloud.com`
  /// this time, not `api-v2.soundcloud.com`, so it is followed directly
  /// with the same [accessToken] header rather than through [pageFor],
  /// which assumes the anonymous, `client_id`-bearing surface.
  ///
  /// Throws `SwayvePluginAuthRequiredException` for a token SoundCloud
  /// rejects (`401`/`403`) — the caller (`SoundCloudLibraryProvider`) has
  /// already attempted one refresh by the time this is reached, so a
  /// rejection here means the whole session needs a fresh sign-in, not
  /// another retry.
  Future<SoundCloudPage> officialMyLikedTracks({
    required String accessToken,
    String? cursor,
    SwayveCancellationToken? cancel,
  }) async {
    final Uri url = cursor == null
        ? Uri.parse('$kOAuthApiOrigin/me/likes/tracks').replace(
            queryParameters: <String, String>{'linked_partitioning': '1'},
          )
        : Uri.tryParse(cursor) ??
            malformedResponse(
              'a pagination cursor from the official API was not a usable '
              'URL: $cursor',
            );
    if (!isAllowedHost(url.host)) {
      throw SwayvePluginUnsupportedException(
        'SoundCloud will not follow a liked-tracks cursor onto '
        '${url.host}: not declared in the plugin manifest.',
      );
    }
    final SwayveHttpResponse response = await _rawGet(
      url,
      headers: <String, String>{'authorization': 'OAuth $accessToken'},
      cancel: cancel,
    );
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const SwayvePluginAuthRequiredException(
        'SoundCloud: sign in to see your liked tracks.',
      );
    }
    if (!response.isSuccess) throwForStatus(response, url);
    final Object? body = response.bodyAsJson;
    if (body is! Map) {
      malformedResponse(
        'expected a JSON object from ${url.host}${url.path} but got '
        '${body.runtimeType}.',
      );
    }
    final Map<String, Object?> json = mapOf(body);
    return SoundCloudPage(
      items: listAt(json, <Object>['collection']),
      nextHref: stringAt(json, <Object>['next_href']),
    );
  }

  /// Exchanges an authorization [code] (from the redirect
  /// `SoundCloudAuthProvider.authenticate` captured) for a fresh
  /// `access_token`/`refresh_token` pair — SoundCloud's own token endpoint,
  /// `POST secure.soundcloud.com/oauth/token`.
  ///
  /// [codeVerifier] is the PKCE verifier the authorize request's
  /// `code_challenge` was derived from — see `auth/pkce.dart`. SoundCloud's
  /// own guide states PKCE is required, not optional, for this exchange.
  Future<Map<String, Object?>> exchangeAuthorizationCode({
    required String clientId,
    required String clientSecret,
    required String code,
    required String codeVerifier,
    SwayveCancellationToken? cancel,
  }) =>
      _tokenRequest(
        <String, String>{
          'grant_type': 'authorization_code',
          'client_id': clientId,
          'client_secret': clientSecret,
          'redirect_uri': kOAuthRedirectUri,
          'code': code,
          'code_verifier': codeVerifier,
        },
        cancel: cancel,
      );

  /// Exchanges a stored `refresh_token` for a new `access_token` (and,
  /// possibly, a rotated `refresh_token` — see
  /// `providers/auth_provider.dart`'s token-storage doc comment for how
  /// that is handled) without any user interaction.
  Future<Map<String, Object?>> refreshAccessToken({
    required String clientId,
    required String clientSecret,
    required String refreshToken,
    SwayveCancellationToken? cancel,
  }) =>
      _tokenRequest(
        <String, String>{
          'grant_type': 'refresh_token',
          'client_id': clientId,
          'client_secret': clientSecret,
          'refresh_token': refreshToken,
        },
        cancel: cancel,
      );

  Future<Map<String, Object?>> _tokenRequest(
    Map<String, String> form, {
    SwayveCancellationToken? cancel,
  }) async {
    if (!isAllowedHost(kOAuthTokenUri.host)) {
      throw SwayvePluginUnsupportedException(
        'SoundCloud will not request ${kOAuthTokenUri.host}: not declared '
        "in the plugin manifest's network.hosts.",
      );
    }
    final SwayveHttpResponse response = await _http.post(
      kOAuthTokenUri,
      headers: const <String, String>{
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
      },
      body: form.entries
          .map(
            (e) => '${Uri.encodeQueryComponent(e.key)}='
                '${Uri.encodeQueryComponent(e.value)}',
          )
          .join('&'),
      timeout: timeouts.request,
      cancel: cancel,
    );
    if (response.statusCode == 400 || response.statusCode == 401) {
      // SoundCloud answers a rejected code or a revoked/expired refresh
      // token this way — `invalid_grant`, in the OAuth spec's own
      // vocabulary — which is not a service failure, it is the flow itself
      // having failed. The caller (`SoundCloudAuthProvider`) turns this
      // into a failed `SwayveAuthState` rather than letting the SDK's
      // generic exception hierarchy speak for it.
      throw SwayvePluginAuthRequiredException(
        'SoundCloud rejected the token exchange '
        '(${response.statusCode}).',
      );
    }
    if (!response.isSuccess) throwForStatus(response, kOAuthTokenUri);
    final Object? body = response.bodyAsJson;
    if (body is! Map) {
      malformedResponse(
        'expected a JSON object from the token endpoint but got '
        '${body.runtimeType}.',
      );
    }
    return mapOf(body);
  }

  /// One page of [id]'s reposts (tracks and playlists both, unfiltered here)
  /// — `/stream/users/{id}/reposts`.
  ///
  /// Confirmed live: each item carries a `type` of `track-repost` or
  /// `playlist-repost`, wrapping the reposted entity under `"track"` or
  /// `"playlist"` respectively alongside `created_at`/`user`/`uuid`.
  /// Filtering to `track-repost` only is `SoundCloudArtistActivityProvider`'s
  /// job, not this client's.
  Future<SoundCloudPage> userReposts(
    int id, {
    String? cursor,
    SwayveCancellationToken? cancel,
  }) =>
      pageFor(cursor, _apiUri('/stream/users/$id/reposts'), cancel: cancel);

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
  ///
  /// Every returned track carries [envelope]'s own id and title as its
  /// [SwayveTrack.album] — [parseTrack] itself never sets one, since a bare
  /// `/tracks/{id}` lookup has no release to credit a song to, but a track
  /// reached *through* a playlist or album very much does, the same way
  /// `YouTubeMusicCatalogProvider`'s own album lookup stamps its tracks with
  /// the release being looked up rather than trusting each item to carry it.
  /// Without this, nothing downstream can tell these songs came from the
  /// same release: `Track.albumId` is exactly what a host groups a release's
  /// songs under, and unset it left every hydrated release ungrouped — its
  /// own request for it notwithstanding.
  Future<List<SwayveTrack>> hydratePlaylistTracks(
    ParsedPlaylistEnvelope envelope, {
    SwayveCancellationToken? cancel,
  }) async {
    final List<int> stubs = stubIdsIn(envelope.rawTracks);
    if (stubs.isEmpty) {
      return _withReleaseRef(
        spliceHydratedTracks(envelope.rawTracks, const <int, SwayveTrack>{}),
        envelope,
      );
    }

    final List<List<int>> batches = <List<int>>[
      for (int start = 0, count = 0;
          start < stubs.length && count < kMaxHydrationBatches;
          start += kTrackBatchSize, count++)
        stubs.sublist(start, math.min(start + kTrackBatchSize, stubs.length)),
    ];

    // Fetched together rather than one after another: each batch asks
    // `/tracks?ids=` for a disjoint set of ids, so nothing about the second
    // batch depends on what the first one answered. A playlist that needs
    // every one of [kMaxHydrationBatches] to hydrate would otherwise pay for
    // ten round trips in series against one operation budget that already has
    // to cover all of them.
    final List<Map<int, SwayveTrack>> results =
        await Future.wait(<Future<Map<int, SwayveTrack>>>[
      for (final List<int> batch in batches) _hydrateBatch(batch, cancel),
    ]);

    final Map<int, SwayveTrack> hydrated = <int, SwayveTrack>{
      for (final Map<int, SwayveTrack> result in results) ...result,
    };
    return _withReleaseRef(
      spliceHydratedTracks(envelope.rawTracks, hydrated),
      envelope,
    );
  }

  /// One hydration batch's tracks, keyed by id — or empty when the batch
  /// itself failed.
  ///
  /// A batch that throws is caught here rather than left to fail the whole
  /// `Future.wait`: its stubs are simply absent from the result, per
  /// [spliceHydratedTracks]'s "keep what was gathered" rule, and one bad
  /// batch must not take the others down with it now that they are in flight
  /// together.
  Future<Map<int, SwayveTrack>> _hydrateBatch(
    List<int> batch,
    SwayveCancellationToken? cancel,
  ) async {
    try {
      final List<Map<String, Object?>> fetched =
          await tracksByIds(batch, cancel: cancel);
      final Map<int, SwayveTrack> hydrated = <int, SwayveTrack>{};
      for (final Map<String, Object?> json in fetched) {
        final SwayveTrack? track = parseTrack(json);
        final int? id = intAt(json, <Object>['id']);
        if (track != null && id != null) hydrated[id] = track;
      }
      return hydrated;
    } on SwayvePluginException {
      return const <int, SwayveTrack>{};
    }
  }

  /// Stamps every track in [tracks] with [envelope]'s own id and title as
  /// its [SwayveTrack.album], unless a track already carries one of its own.
  List<SwayveTrack> _withReleaseRef(
    List<SwayveTrack> tracks,
    ParsedPlaylistEnvelope envelope,
  ) {
    final SwayveAlbumRef ref = SwayveAlbumRef(
      id: SoundCloudIds.playlist(envelope.id),
      title: envelope.title,
    );
    return [
      for (final SwayveTrack track in tracks)
        track.album == null ? track.copyWith(album: ref) : track,
    ];
  }
}
