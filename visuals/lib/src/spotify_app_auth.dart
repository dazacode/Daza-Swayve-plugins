import 'dart:async';
import 'dart:convert';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'errors.dart';

/// Turns a registered Spotify application's client id and secret into a
/// bearer token for the documented Web API.
///
/// ## Why there are two Spotify credentials rather than one
///
/// The canvas lookup needs a track's `spotify:track:…` URI, and the host
/// never hands a visuals provider an id from somebody else's catalogue — so
/// the recording has to be resolved by searching. The obvious move was to
/// search with the same web-player token the canvas call uses, since minting
/// it was already necessary.
///
/// That does not work, and it fails in the least helpful way available.
/// `api.spotify.com` answers a web-player token with `429 API rate limit
/// exceeded` on the very first request and every one after it, regardless of
/// headers: the public Web API is simply not a door that token opens. The
/// plugin then had no URI, declined, and reported "no canvas for this
/// recording" — a confident, wrong answer, with the account session working
/// perfectly and the canvas endpoint answering perfectly on either side of it.
///
/// So the two jobs use the two credentials that are actually entitled to
/// them. This one — an *application* credential, exactly like the TIDAL pair,
/// identifying the app rather than a person — searches the documented API.
/// The `sp_dc` session cookie in `spotify_auth.dart` is used for the canvas
/// call alone, which no documented API offers.
///
/// The division is worth keeping even if a shortcut appears later: a session
/// cookie should touch as little as possible, and searching a public
/// catalogue is not something anybody's account needs to be involved in.
final class SpotifyAppTokenSource {
  /// Creates a token source over the host-mediated HTTP transport.
  SpotifyAppTokenSource({
    required SwayveHttpClient http,
    required String? Function() clientId,
    required String? Function() clientSecret,
    this.timeouts = VisualsTimeouts.manifest,
    DateTime Function()? now,
  })  : _http = http,
        _clientId = clientId,
        _clientSecret = clientSecret,
        _now = now ?? DateTime.now;

  final SwayveHttpClient _http;
  final String? Function() _clientId;
  final String? Function() _clientSecret;
  final DateTime Function() _now;

  /// The request budget for a mint.
  final VisualsTimeouts timeouts;

  String? _token;
  DateTime? _expiry;
  Future<String>? _minting;

  /// Whether both halves of the application credential are present.
  bool get isConfigured =>
      (_clientId()?.trim().isNotEmpty ?? false) &&
      (_clientSecret()?.trim().isNotEmpty ?? false);

  /// Whether exactly one half is present.
  ///
  /// Somebody who pasted an id and stopped has tried and failed to configure
  /// this, and saying so is more useful than silence.
  bool get isHalfConfigured =>
      !isConfigured &&
      ((_clientId()?.trim().isNotEmpty ?? false) ||
          (_clientSecret()?.trim().isNotEmpty ?? false));

  /// Forgets the cached token, so the next call mints a fresh one.
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
        _now().isBefore(expiry.subtract(const Duration(minutes: 1)))) {
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
        'Spotify canvases also need a Spotify application client id and '
        'secret, which is what looks the recording up. Create one at '
        'developer.spotify.com and add both.',
      );
    }

    final String basic = base64Encode(utf8.encode('$id:$secret'));
    final SwayveHttpResponse response = await _http.post(
      kSpotifyAccountsTokenEndpoint,
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
        'Spotify rejected the application client id and secret.',
      );
    }
    if (!response.isSuccess) {
      throw exceptionForStatus(response.statusCode, headers: response.headers);
    }

    final Object? decoded = response.bodyAsJson;
    if (decoded is! Map<String, Object?>) {
      throw SwayvePluginMalformedResponseException(
        'The Spotify accounts endpoint returned a JSON document instead of '
        'an object.',
      );
    }
    final Object? token = decoded['access_token'];
    if (token is! String || token.isEmpty) {
      throw SwayvePluginMalformedResponseException(
        'The Spotify accounts endpoint returned no access_token.',
      );
    }

    // `expires_in` is documented in seconds. Anything absent or absurd is
    // treated as a short life: minting again early costs one request, while
    // trusting a bad expiry costs every lookup until restart.
    final Object? expiresIn = decoded['expires_in'];
    final int seconds = expiresIn is int
        ? expiresIn
        : expiresIn is num
            ? expiresIn.toInt()
            : 0;
    _token = token;
    _expiry = _now().add(
      Duration(seconds: seconds > 0 && seconds < 86400 * 7 ? seconds : 300),
    );
    return token;
  }
}
