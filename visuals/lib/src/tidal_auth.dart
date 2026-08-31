import 'dart:async';
import 'dart:convert';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'errors.dart';

/// Turns a TIDAL application's client id and secret into a bearer token.
///
/// The plugin asks for an id and a secret rather than a ready-made access
/// token because a TIDAL access token expires within the day. A setting
/// holding one would work until it silently stopped, with nothing on screen
/// to say why and nowhere to look but the developer portal. An id and a
/// secret are the credential that does not rot, and minting from them is
/// three lines of HTTP.
///
/// The token is held in memory only. It is deliberately never written to
/// plugin storage: it is derived state with a short life, re-mintable at any
/// moment from settings that *are* stored, and writing it down would be one
/// more copy of a bearer token on disk for no gain.
final class TidalTokenSource {
  /// Creates a token source over the host-mediated HTTP transport.
  TidalTokenSource({
    required SwayveHttpClient http,
    required String? Function() clientId,
    required String? Function() clientSecret,
    this.timeouts = VisualsTimeouts.manifest,
  })  : _http = http,
        _clientId = clientId,
        _clientSecret = clientSecret;

  final SwayveHttpClient _http;
  final String? Function() _clientId;
  final String? Function() _clientSecret;

  /// The request budget for a mint.
  final VisualsTimeouts timeouts;

  String? _token;
  DateTime? _expiry;

  /// One mint in flight at a time.
  ///
  /// A track change asks several sources at once and the host asks for a
  /// visual again the moment the now-playing screen reopens. Without this,
  /// the first few lookups after a cold start would each mint a token of
  /// their own and throw all but one away.
  Future<String>? _minting;

  /// Whether the plugin has been given anything to mint from.
  ///
  /// False is not an error: this plugin resolves covers without credentials
  /// too, and an unconfigured official source should stand aside quietly
  /// rather than announce a failure the person never asked for.
  bool get isConfigured =>
      (_clientId()?.trim().isNotEmpty ?? false) &&
      (_clientSecret()?.trim().isNotEmpty ?? false);

  /// Whether exactly one half of the credential is present.
  ///
  /// Worth distinguishing from [isConfigured]: somebody who pasted an id and
  /// stopped has tried and failed to configure this, and telling them so is
  /// more useful than silence.
  bool get isHalfConfigured =>
      !isConfigured &&
      ((_clientId()?.trim().isNotEmpty ?? false) ||
          (_clientSecret()?.trim().isNotEmpty ?? false));

  /// Forgets the cached token, so the next call mints a fresh one.
  ///
  /// Called when TIDAL answers 401 with a token this thought was still
  /// valid — a secret rotated in the portal, or a clock far enough out that
  /// the local expiry disagreed with theirs.
  void invalidate() {
    _token = null;
    _expiry = null;
  }

  /// A valid bearer token, minting one if the cached token is missing or due
  /// to expire within the next minute.
  Future<String> token({SwayveCancellationToken? cancel}) {
    final String? cached = _token;
    final DateTime? expiry = _expiry;
    if (cached != null &&
        expiry != null &&
        DateTime.now().isBefore(expiry.subtract(const Duration(minutes: 1)))) {
      return Future<String>.value(cached);
    }
    final Future<String>? running = _minting;
    if (running != null) return running;

    final Future<String> run = _mint(cancel: cancel).whenComplete(() {
      _minting = null;
    });
    _minting = run;
    return run;
  }

  Future<String> _mint({SwayveCancellationToken? cancel}) async {
    final String? id = _clientId()?.trim();
    final String? secret = _clientSecret()?.trim();
    if (id == null || id.isEmpty || secret == null || secret.isEmpty) {
      throw const SwayvePluginAuthRequiredException(
        'Add the TIDAL application client id and secret to use the official '
        'TIDAL catalog.',
      );
    }

    final String basic = base64Encode(utf8.encode('$id:$secret'));
    final SwayveHttpResponse response = await _http.post(
      kTidalTokenEndpoint,
      headers: <String, String>{
        'authorization': 'Basic $basic',
        'content-type': 'application/x-www-form-urlencoded',
        'accept': 'application/json',
        'user-agent': kUserAgent,
      },
      body: 'grant_type=client_credentials',
      timeout: timeouts.request,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    if (response.statusCode == 400 || response.statusCode == 401) {
      throw const SwayvePluginAuthRequiredException(
        'TIDAL rejected the client id and secret.',
      );
    }
    if (!response.isSuccess) {
      throw exceptionForStatus(response.statusCode, headers: response.headers);
    }

    final Object? decoded = response.bodyAsJson;
    if (decoded is! Map<String, Object?>) {
      throw SwayvePluginMalformedResponseException(
        'The TIDAL token endpoint returned a JSON document instead of an '
        'object.',
      );
    }
    final Object? token = decoded['access_token'];
    if (token is! String || token.isEmpty) {
      throw SwayvePluginMalformedResponseException(
        'The TIDAL token endpoint returned no access_token.',
      );
    }

    // `expires_in` is documented in seconds. Treat anything absent or absurd
    // as a short life rather than a long one: minting again early costs one
    // request, while trusting a bad expiry costs every lookup until restart.
    final Object? expiresIn = decoded['expires_in'];
    final int seconds = expiresIn is int
        ? expiresIn
        : expiresIn is num
            ? expiresIn.toInt()
            : 0;
    _token = token;
    _expiry = DateTime.now().add(
      Duration(seconds: seconds > 0 && seconds < 86400 * 7 ? seconds : 300),
    );
    return token;
  }
}
