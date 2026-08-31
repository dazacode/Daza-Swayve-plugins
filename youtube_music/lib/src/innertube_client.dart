import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'auth/sapisid_hash.dart';
import 'config.dart';
import 'errors.dart';
import 'json_path.dart';

/// A small, focused client for YouTube Music's InnerTube API, layered over the
/// **host-provided** [SwayveHttpClient].
///
/// This is the load-bearing design decision of the whole plugin. It owns URL
/// construction, the InnerTube request envelope, status-code interpretation
/// and JSON decoding — and it owns no transport at all. There is no socket, no
/// `dart:io`, no `package:http`, no connection pool and no cookie jar here;
/// every byte goes through [SwayveHttpClient], which is the object the host
/// uses to enforce the `network` permission and the manifest's
/// `network.hosts` allowlist.
///
/// A plugin that opened its own socket would still *work*, and would have
/// escaped the permission model entirely. That is why this type takes a
/// client rather than creating one, and why [postJson] refuses a URL outside
/// [kYouTubeMusicAllowedHosts] before the host ever has to.
final class InnerTubeClient {
  /// Creates a client bound to one plugin context's facilities.
  InnerTubeClient({
    required SwayveHttpClient http,
    required SwayveSettingsView settings,
    required SwayveHostInfo host,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  })  : _http = http,
        _settings = settings,
        _host = host;

  final SwayveHttpClient _http;
  final SwayveSettingsView _settings;
  final SwayveHostInfo _host;

  /// The deadlines this client works to.
  final YouTubeMusicTimeouts timeouts;

  static final RegExp _regionCode = RegExp(r'^[A-Za-z]{2}$');

  /// The region to ask YouTube Music about, as an ISO-3166 alpha-2 code.
  ///
  /// Read fresh on every request rather than cached at initialize time: the
  /// user can change the setting while the plugin is running, and a cached
  /// copy would quietly keep serving the old catalogue.
  ///
  /// The order is user choice, then the host's own region, then the
  /// manifest's declared default — so the setting always wins, and a host that
  /// knows the user's region still beats a hardcoded `US`.
  String get region {
    final String? chosen = _settings.value<String>(kRegionSettingId);
    if (chosen != null && _regionCode.hasMatch(chosen)) {
      return chosen.toUpperCase();
    }
    final String? hostRegion = _host.region;
    if (hostRegion != null && _regionCode.hasMatch(hostRegion)) {
      return hostRegion.toUpperCase();
    }
    return kDefaultRegion;
  }

  /// The language to ask for, as the primary subtag of the host's BCP-47
  /// locale.
  ///
  /// InnerTube's `hl` wants a language, not a full locale: the country half of
  /// `en-GB` is what `gl` carries, and sending it twice narrows results for no
  /// benefit.
  String get language {
    final String locale = _host.locale.trim();
    if (locale.isEmpty) return 'en';
    final int separator = locale.indexOf(RegExp('[-_]'));
    final String primary =
        separator == -1 ? locale : locale.substring(0, separator);
    return primary.isEmpty ? 'en' : primary.toLowerCase();
  }

  /// Runs an InnerTube search.
  ///
  /// [params] is the opaque filter blob that scopes the search to one kind of
  /// result; [continuation] fetches the page after a previous response's
  /// cursor.
  Future<Map<String, Object?>> search(
    String query, {
    String? params,
    String? continuation,
    SwayveCancellationToken? cancel,
  }) =>
      postJson(
        kSearchEndpoint,
        <String, Object?>{
          'query': query,
          if (params != null) 'params': params,
          if (continuation != null) 'continuation': continuation,
        },
        cancel: cancel,
      );

  /// Runs an InnerTube browse for [browseId].
  ///
  /// [sessionCookie] is the InnerTube session cookie the user pasted into the
  /// `session_cookie` setting (see `providers/auth_provider.dart`), for the
  /// handful of browse ids — the signed-in user's own liked-music playlist
  /// among them — that only answer for a signed-in session. It is optional
  /// and additive: every existing call site passes nothing here and gets
  /// exactly the anonymous request this client has always sent, unchanged.
  /// When present, the request carries a `cookie` header plus the
  /// `authorization` header InnerTube expects alongside it — see
  /// [_authenticatedHeaders] and `auth/sapisid_hash.dart`.
  ///
  /// [pageId] is the `page_id` setting's value — see [kPageIdSettingId] — sent
  /// as `x-goog-pageid` when present. A cookie identifies a *session*; some
  /// Google accounts carry more than one YouTube channel underneath it, and
  /// without this InnerTube answers for whichever channel it treats as
  /// default. Null (the ordinary case: one channel) sends no such header,
  /// unchanged from before this parameter existed.
  Future<Map<String, Object?>> browse(
    String browseId, {
    String? params,
    String? continuation,
    String? sessionCookie,
    String? pageId,
    SwayveCancellationToken? cancel,
  }) =>
      postJson(
        kBrowseEndpoint,
        <String, Object?>{
          'browseId': browseId,
          if (params != null) 'params': params,
          if (continuation != null) 'continuation': continuation,
        },
        cancel: cancel,
        extraHeaders: _authenticatedHeaders(sessionCookie, pageId: pageId),
      );

  /// Asks "what plays after this" for [videoId] within [playlistId].
  ///
  /// The request the web app makes when a radio is started: the seed video,
  /// the station's own playlist id, and the opaque `params` blob that says
  /// "build me a station" rather than "open this playlist".
  ///
  /// Sent as the ordinary [envelope]: `next` is a music-app endpoint and
  /// `WEB_REMIX` is the client that serves it.
  ///
  /// Note what is deliberately *not* sent: `isAudioOnly`. Measured against
  /// the live endpoint, sending it changes nothing at all — the same fifty
  /// `MUSIC_VIDEO_TYPE_OMV` rows come back either way. Audio-only is a
  /// client-side filter on each row's own `musicVideoType`; see
  /// `parsing/watch_parser.dart`.
  Future<Map<String, Object?>> next(
    String videoId, {
    required String playlistId,
    String? params,
    SwayveCancellationToken? cancel,
  }) =>
      postJson(
        kNextEndpoint,
        <String, Object?>{
          'videoId': videoId,
          'playlistId': playlistId,
          if (params != null) 'params': params,
        },
        cancel: cancel,
      );

  /// Fetches the page of a station after [continuation].
  ///
  /// Context and cursor and nothing else — a continuation names the whole
  /// request that produced it, so re-stating the seed would be describing a
  /// different one.
  Future<Map<String, Object?>> nextContinuation(
    String continuation, {
    SwayveCancellationToken? cancel,
  }) =>
      postJson(
        kNextEndpoint,
        <String, Object?>{'continuation': continuation},
        cancel: cancel,
      );

  /// Resolves [videoId] to a player response for the sake of its caption
  /// tracks, asked as [client].
  ///
  /// A separate call from [player] rather than a flag on it, and asked as a
  /// separately declared identity — see [kCaptionsClients] for which clients
  /// answer this at all, which do not, and why the list is a chain rather
  /// than one name. The caller decides how far down that chain to walk; this
  /// makes exactly one request. Nothing here reads the streaming half of the
  /// response.
  Future<Map<String, Object?>> captionsPlayer(
    String videoId, {
    required YouTubeMusicClientIdentity client,
    SwayveCancellationToken? cancel,
  }) async {
    final String? visitor = await visitorData(cancel: cancel);
    return postJson(
      kPlayerEndpoint,
      <String, Object?>{
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
      },
      cancel: cancel,
      envelopeOverride: _captionsEnvelope(client, visitor),
      extraHeaders: <String, String>{
        'x-youtube-client-name': client.id,
        'x-youtube-client-version': client.version,
        if (visitor != null) 'x-goog-visitor-id': visitor,
      },
    );
  }

  /// GETs [url] and returns its body as text.
  ///
  /// The one non-InnerTube fetch this client makes: a caption track is served
  /// as XML from a signed `timedtext` URL, not as JSON from an endpoint. It
  /// still goes through [SwayveHttpClient] and still refuses a host outside
  /// [kYouTubeMusicAllowedHosts] before the request is made, exactly as
  /// [postJson] does — the whole point of this type is that there is no
  /// second way out of the plugin.
  Future<String> getText(Uri url, {SwayveCancellationToken? cancel}) async {
    if (!isAllowedHost(url.host)) {
      throw SwayvePluginUnsupportedException(
        'YouTube Music will not contact ${url.host}: it is not one of the '
        'hosts declared in the plugin manifest.',
      );
    }
    final SwayveHttpResponse response = await _http.get(
      url,
      headers: <String, String>{
        'accept': '*/*',
        'accept-language': _host.locale,
      },
      timeout: timeouts.request,
      cancel: cancel,
    );
    if (!response.isSuccess) throwForStatus(response, url);
    return response.bodyAsString;
  }

  /// The visitor identity every player request carries.
  ///
  /// ## Why this exists
  ///
  /// Without one, the player endpoint answers a handful of requests and then
  /// starts refusing with "Sign in to confirm you're not a bot" — not for one
  /// video, but for every video, until something changes. With one cached and
  /// reused it answers normally. It is the difference between a plugin that
  /// plays music and a plugin that plays music for ninety seconds.
  ///
  /// ## Why it is not persisted
  ///
  /// It is a session token, and a stale one is worse than none: a token minted
  /// weeks ago on another network is exactly the shape of thing that gets a
  /// request refused, and the plugin's own storage would keep handing it back
  /// after every restart. Minted once per running instance, re-minted when a
  /// request is refused, and forgotten when the plugin stops.
  String? _visitorData;

  /// Returns the cached visitor identity, minting one if there is none.
  ///
  /// A failure here is not fatal and is not reported. The first few player
  /// requests work without an identity, so a plugin that refused to play
  /// anything because it could not mint one would be failing in a case that
  /// still had a chance of working.
  Future<String?> visitorData({SwayveCancellationToken? cancel}) async {
    final String? held = _visitorData;
    if (held != null) return held;
    try {
      final Map<String, Object?> response = await postJson(
        kVisitorEndpoint,
        const <String, Object?>{},
        cancel: cancel,
        envelopeOverride: _visitorEnvelope,
      );
      final String? value = stringAt(response, const <Object>[
        'responseContext',
        'visitorData',
      ]);
      if (value is String && value.isNotEmpty) {
        _visitorData = value;
        return value;
      }
    } on SwayvePluginException {
      // Left null. The caller sends the request without one and may well be
      // answered; if it is not, [forgetVisitorData] and one retry is the whole
      // recovery path.
    }
    return null;
  }

  /// Drops the cached identity so the next request mints a fresh one.
  ///
  /// Called when a player request comes back refused, which is the one signal
  /// that the identity in hand has stopped being accepted.
  void forgetVisitorData() => _visitorData = null;

  /// Resolves [videoId] to the player response holding its media streams.
  ///
  /// Asked as [kPlayerClientName] rather than the client search and browse
  /// use — see that constant for why those two cannot be the same, and for how
  /// long this is likely to keep working.
  Future<Map<String, Object?>> player(
    String videoId, {
    SwayveCancellationToken? cancel,
  }) async {
    final String? visitor = await visitorData(cancel: cancel);
    return postJson(
      kPlayerEndpoint,
      <String, Object?>{
        'videoId': videoId,
        // Both suppress an interstitial that would otherwise come back in
        // place of the streams for anything flagged as sensitive. Neither
        // claims an age or an identity; they say the caller has already been
        // shown whatever warning applies, which for a music player it has —
        // the user chose the song.
        'contentCheckOk': true,
        'racyCheckOk': true,
        'playbackContext': const <String, Object?>{
          'contentPlaybackContext': <String, Object?>{
            'html5Preference': 'HTML5_PREF_WANTS',
          },
        },
      },
      cancel: cancel,
      envelopeOverride: _playerEnvelope(visitor),
      extraHeaders: <String, String>{
        'x-youtube-client-name': kPlayerClientId,
        'x-youtube-client-version': kPlayerClientVersion,
        if (visitor != null) 'x-goog-visitor-id': visitor,
      },
    );
  }

  /// POSTs [payload] wrapped in the InnerTube envelope and returns the decoded
  /// JSON object.
  ///
  /// Failure handling in one place:
  /// * a URL outside the manifest's allowlist is refused here, before the
  ///   request is made;
  /// * transport failures, host-side timeouts and cancellation arrive as
  ///   `SwayvePluginException`s from [SwayveHttpClient] and are left alone;
  /// * a non-2xx status goes to [throwForStatus];
  /// * a body that is not JSON, or is JSON but not an object, becomes
  ///   `SwayvePluginMalformedResponseException`.
  ///
  /// [envelopeOverride] replaces the default [envelope] for the requests that
  /// have to claim a different client identity — see [player]. [extraHeaders]
  /// are merged over [requestHeaders] for the same reason.
  Future<Map<String, Object?>> postJson(
    Uri url,
    Map<String, Object?> payload, {
    SwayveCancellationToken? cancel,
    Map<String, Object?>? envelopeOverride,
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    if (!isAllowedHost(url.host)) {
      throw SwayvePluginUnsupportedException(
        'YouTube Music will not contact ${url.host}: it is not one of the '
        'hosts declared in the plugin manifest.',
      );
    }
    final SwayveHttpResponse response = await _http.post(
      url.replace(
        queryParameters: <String, String>{
          ...url.queryParameters,
          'prettyPrint': 'false',
        },
      ),
      headers: <String, String>{...requestHeaders, ...extraHeaders},
      body: <String, Object?>{...envelopeOverride ?? envelope, ...payload},
      timeout: timeouts.request,
      cancel: cancel,
    );
    if (!response.isSuccess) throwForStatus(response, url);
    final Object? decoded = response.bodyAsJson;
    if (decoded is! Map) {
      malformedResponse(
        '${url.path} answered with a ${decoded.runtimeType} where a JSON '
        'object was expected.',
      );
    }
    return mapOf(decoded);
  }

  /// The InnerTube context envelope every request carries.
  ///
  /// It identifies the client YouTube Music's own web player uses and states
  /// the language and region to answer in.
  Map<String, Object?> get envelope => <String, Object?>{
        'context': <String, Object?>{
          'client': <String, Object?>{
            'clientName': kInnerTubeClientName,
            'clientVersion': kInnerTubeClientVersion,
            'hl': language,
            'gl': region,
          },
          'user': <String, Object?>{'lockedSafetyMode': false},
        },
      };

  /// The envelope the player endpoint is asked with.
  ///
  /// A separate identity from [envelope] rather than a variation on it: the
  /// two name different clients, and a client identity is a set of fields
  /// rather than a name, so mixing halves of two of them is a request InnerTube
  /// may simply stop recognising. See [kPlayerClientName].
  Map<String, Object?> _playerEnvelope(String? visitor) => <String, Object?>{
        'context': <String, Object?>{
          'client': <String, Object?>{
            'clientName': kPlayerClientName,
            'clientVersion': kPlayerClientVersion,
            'deviceMake': kPlayerDeviceMake,
            'deviceModel': kPlayerDeviceModel,
            'osName': kPlayerOsName,
            'osVersion': kPlayerOsVersion,
            'hl': language,
            'gl': region,
            if (visitor != null) 'visitorData': visitor,
          },
          'user': <String, Object?>{'lockedSafetyMode': false},
          'request': <String, Object?>{'useSsl': true},
        },
      };

  /// The envelope the captions half of a player response is asked with.
  ///
  /// Built from [client] rather than from constants, because [kCaptionsClients]
  /// is a chain and this is called once per link. The device fields are sent
  /// only when the identity carries them: each entry in that list is sent as
  /// exactly the context measured to answer, and inventing a device for a
  /// client that was proven without one would be changing the request that
  /// was actually tested.
  Map<String, Object?> _captionsEnvelope(
    YouTubeMusicClientIdentity client,
    String? visitor,
  ) =>
      <String, Object?>{
        'context': <String, Object?>{
          'client': <String, Object?>{
            'clientName': client.name,
            'clientVersion': client.version,
            if (client.deviceMake != null) 'deviceMake': client.deviceMake,
            if (client.deviceModel != null) 'deviceModel': client.deviceModel,
            if (client.osName != null) 'osName': client.osName,
            if (client.osVersion != null) 'osVersion': client.osVersion,
            'hl': language,
            'gl': region,
            if (visitor != null) 'visitorData': visitor,
          },
          'user': <String, Object?>{'lockedSafetyMode': false},
        },
      };

  /// The envelope a visitor identity is minted with.
  ///
  /// The plain web client. The identity it returns is not tied to the client
  /// that asked for it, so there is nothing to be gained by claiming to be
  /// something more specific.
  Map<String, Object?> get _visitorEnvelope => <String, Object?>{
        'context': <String, Object?>{
          'client': <String, Object?>{
            'clientName': kVisitorClientName,
            'clientVersion': kVisitorClientVersion,
            'hl': language,
            'gl': region,
          },
        },
      };

  /// The headers every request carries.
  ///
  /// No `user-agent` and no cookie by default: the host owns the transport,
  /// and an ordinary request carries no session. [browse]'s [sessionCookie]
  /// parameter is the one, opt-in exception — see [_authenticatedHeaders] —
  /// and even then nothing is held here between calls: this client stores no
  /// cookie jar, only ever attaches the one a caller hands it for that single
  /// request.
  Map<String, String> get requestHeaders => <String, String>{
        'content-type': 'application/json',
        'accept': '*/*',
        'accept-language': _host.locale,
        'origin': kMusicOrigin,
        'referer': '$kMusicOrigin/',
        'x-youtube-client-name': kInnerTubeClientId,
        'x-youtube-client-version': kInnerTubeClientVersion,
      };

  /// The extra headers an authenticated [browse] call carries, or none.
  ///
  /// A `null` or empty [sessionCookie] is the ordinary, anonymous case and
  /// returns no headers at all — the request is byte-for-byte what it always
  /// was. A present cookie adds it as a `cookie` header plus the
  /// `authorization` header InnerTube's authenticated endpoints expect
  /// alongside it (`SAPISIDHASH`, computed in `auth/sapisid_hash.dart` — see
  /// that file for exactly what is and is not verified about it) and
  /// `x-goog-authuser: 0`, which unofficial YouTube Music clients send
  /// alongside it to select the first Google account on the session. Always
  /// `0`: this plugin has no notion of *which* signed-in Google account to
  /// act as beyond the one the pasted cookie itself carries — see [pageId]
  /// for the separate axis that actually varies per user, which channel
  /// under that one account.
  ///
  /// [pageId], when present, is sent as [kPageIdHeader] — see
  /// [kPageIdSettingId]'s doc comment for what it selects and why a cookie
  /// alone does not settle it. Confirmed empirically (not merely inferred
  /// from other clients, unlike the rest of this method) against a real
  /// multi-channel account: without it, a channel's own Liked Music playlist
  /// answered as a normal, parseable, entirely empty page — no error, no
  /// "signed out" placeholder, nothing to catch — with it, the same request
  /// answered with the real count.
  ///
  /// Never logged: this plugin has no `context.log` call anywhere near this
  /// path, and it must stay that way — see `docs/permissions.md`'s "Tokens
  /// and logs" section.
  Map<String, String> _authenticatedHeaders(
    String? sessionCookie, {
    String? pageId,
  }) {
    if (sessionCookie == null || sessionCookie.trim().isEmpty) {
      return const <String, String>{};
    }
    final String? authorization = sapisidHashAuthorization(
      sessionCookie,
      kMusicOrigin,
    );
    return <String, String>{
      'cookie': sessionCookie,
      if (authorization != null) 'authorization': authorization,
      'x-goog-authuser': '0',
      if (pageId != null && pageId.trim().isNotEmpty) kPageIdHeader: pageId,
    };
  }
}
