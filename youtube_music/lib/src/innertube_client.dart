import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

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
  Future<Map<String, Object?>> browse(
    String browseId, {
    String? params,
    String? continuation,
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
      );

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
  /// No `user-agent` and no cookie: the host owns the transport, this plugin
  /// carries no session, and pretending otherwise would be both dishonest and
  /// unreliable.
  Map<String, String> get requestHeaders => <String, String>{
        'content-type': 'application/json',
        'accept': '*/*',
        'accept-language': _host.locale,
        'origin': kMusicOrigin,
        'referer': '$kMusicOrigin/',
        'x-youtube-client-name': kInnerTubeClientId,
        'x-youtube-client-version': kInnerTubeClientVersion,
      };
}
