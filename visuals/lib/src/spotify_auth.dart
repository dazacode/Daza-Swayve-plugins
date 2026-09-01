import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'errors.dart';
import 'spotify_totp.dart';

/// Turns an `sp_dc` session cookie into a Spotify web-player access token.
///
/// Shaped after [TidalTokenSource] on purpose — same caching, same in-flight
/// deduplication, same refusal to write the minted token anywhere — but the
/// credential behind it is a different kind of thing, and the difference is
/// worth stating plainly:
///
/// TIDAL's source holds an *application* credential. It identifies this
/// plugin to TIDAL and grants access to a public catalogue. `sp_dc` is a
/// *session* cookie for a real Spotify account: whoever holds it can act as
/// that account. This class therefore does three things the TIDAL one does
/// not need to.
///
/// 1. It is off unless somebody deliberately turned it on. There is no
///    default, no prompt, and no flow anywhere in Swayve that obtains an
///    `sp_dc` for you — a person who wants this pastes one in knowingly.
/// 2. It sends the cookie to exactly one host, `open.spotify.com`, and only
///    to mint a token. The search and canvas requests carry the short-lived
///    bearer token instead, never the cookie.
/// 3. It never logs it, never stores a copy, and never puts it in an
///    exception message. The SDK's secret settings keep it in the platform
///    credential store; nothing here takes it out of there for longer than
///    one request.
///
/// The minted token, like TIDAL's, is memory-only derived state.
final class SpotifyTokenSource {
  /// Creates a token source over the host-mediated HTTP transport.
  SpotifyTokenSource({
    required SwayveHttpClient http,
    required String? Function() spDc,
    String? Function()? totpVersion,
    this.timeouts = VisualsTimeouts.manifest,
    DateTime Function()? now,
  })  : _http = http,
        _spDc = spDc,
        _totpVersion = totpVersion ?? (() => null),
        _now = now ?? DateTime.now;

  final SwayveHttpClient _http;
  final String? Function() _spDc;
  final String? Function() _totpVersion;
  final DateTime Function() _now;

  /// The request budget for a mint.
  final VisualsTimeouts timeouts;

  String? _token;
  DateTime? _expiry;
  Future<String>? _minting;

  /// The offset between this device's clock and Spotify's, once learned.
  ///
  /// A code computed from a clock more than half a period out is simply
  /// wrong, and a phone whose clock drifts is not an exotic case. Spotify
  /// publishes its own time, so the first mint asks and every mint after uses
  /// what it learned. Null means "not asked yet", not "no offset".
  Duration? _clockOffset;

  /// Whether a session cookie has been provided.
  ///
  /// False is not an error: this plugin finds animated covers without Spotify
  /// entirely, and an unconfigured optional source stands aside quietly.
  bool get isConfigured => (_spDc()?.trim().isNotEmpty ?? false);

  /// The TOTP secret version in force — the setting override, or the
  /// embedded default.
  int get totpVersion {
    final int? override = int.tryParse(_totpVersion()?.trim() ?? '');
    return override != null && override > 0 ? override : kSpotifyTotpVersion;
  }

  /// Forgets the cached token, so the next call mints a fresh one.
  void invalidate() {
    _token = null;
    _expiry = null;
  }

  /// A valid access token, minting one if the cached token is missing or due
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
    final String? cookie = _spDc()?.trim();
    if (cookie == null || cookie.isEmpty) {
      throw const SwayvePluginAuthRequiredException(
        'Add a Spotify sp_dc session cookie to use Spotify canvases.',
      );
    }

    final DateTime serverNow = await _serverTime(cookie, cancel: cancel);
    final String code = spotifyTotpAt(serverNow);

    // Both `totp` and `totpServer` carry the same code, computed from the
    // server's clock. They are two parameters because the web player sends
    // one from its own clock and one from the server's; sending the
    // server-derived code for both is the version that keeps working on a
    // device whose clock is wrong, which is the only reason the second
    // parameter exists.
    final Uri endpoint = kSpotifyTokenEndpoint.replace(
      queryParameters: <String, String>{
        'reason': 'init',
        'productType': 'web-player',
        'totp': code,
        'totpServer': code,
        'totpVer': '$totpVersion',
      },
    );

    final SwayveHttpResponse response = await _http.get(
      endpoint,
      headers: _webHeaders(cookie),
      timeout: timeouts.request,
      cancel: cancel,
    );
    cancel?.throwIfCancelled();

    if (response.statusCode == 400 || response.statusCode == 401) {
      throw const SwayvePluginAuthRequiredException(
        'Spotify rejected the sp_dc cookie. It may have expired, or the '
        'embedded TOTP secret version may have been rotated.',
      );
    }
    if (!response.isSuccess) {
      throw exceptionForStatus(response.statusCode, headers: response.headers);
    }

    final Object? decoded = response.bodyAsJson;
    if (decoded is! Map<String, Object?>) {
      throw SwayvePluginMalformedResponseException(
        'The Spotify token endpoint returned a JSON document instead of an '
        'object.',
      );
    }

    final Object? token = decoded['accessToken'];
    if (token is! String || token.isEmpty) {
      throw const SwayvePluginAuthRequiredException(
        'Spotify returned no access token for this sp_dc cookie.',
      );
    }

    // The check this endpoint actually requires, and the one whose absence
    // made a wrong cookie indistinguishable from a song with no canvas.
    //
    // A rejected cookie is not an HTTP error here. The endpoint answers 200
    // with a complete, valid, *anonymous* token — the same token it hands a
    // logged-out browser — and an anonymous session can see no canvases at
    // all. Accepting it meant every request afterwards succeeded and returned
    // nothing, so the lookup reported "no canvas for this recording" with
    // total confidence when what had happened was "you are not signed in".
    //
    // Verified against the live endpoint: called with no cookie whatsoever it
    // returns 200, an accessToken, and isAnonymous: true.
    if (decoded['isAnonymous'] == true) {
      throw const SwayvePluginAuthRequiredException(
        'Spotify issued an anonymous session, which cannot see canvases. The '
        'sp_dc cookie was not accepted — it has probably expired, or was '
        'copied incompletely.',
      );
    }

    // `accessTokenExpirationTimestampMs` is absolute, unlike TIDAL's relative
    // `expires_in`. Anything missing or already past is treated as a short
    // life: minting again early costs one request, trusting a bad expiry
    // costs every lookup until restart.
    final Object? expiresAt = decoded['accessTokenExpirationTimestampMs'];
    final int? millis = expiresAt is int
        ? expiresAt
        : expiresAt is num
            ? expiresAt.toInt()
            : null;
    final DateTime fallback = _now().add(const Duration(minutes: 5));
    final DateTime expiry =
        millis == null ? fallback : DateTime.fromMillisecondsSinceEpoch(millis);

    _token = token;
    _expiry = expiry.isAfter(_now()) ? expiry : fallback;
    return token;
  }

  /// Spotify's clock, or this device's when Spotify will not say.
  Future<DateTime> _serverTime(
    String cookie, {
    SwayveCancellationToken? cancel,
  }) async {
    final Duration? known = _clockOffset;
    if (known != null) return _now().add(known);

    try {
      final SwayveHttpResponse response = await _http.get(
        kSpotifyServerTimeEndpoint,
        headers: _webHeaders(cookie),
        timeout: timeouts.request,
        cancel: cancel,
      );
      cancel?.throwIfCancelled();
      if (response.isSuccess) {
        final Object? decoded = response.bodyAsJson;
        if (decoded is Map<String, Object?>) {
          final Object? seconds = decoded['serverTime'];
          final int? epochSeconds = seconds is int
              ? seconds
              : seconds is num
                  ? seconds.toInt()
                  : int.tryParse('$seconds');
          if (epochSeconds != null && epochSeconds > 0) {
            final DateTime server = DateTime.fromMillisecondsSinceEpoch(
              epochSeconds * 1000,
            );
            _clockOffset = server.difference(_now());
            return server;
          }
        }
      }
    } on SwayvePluginCancelledException {
      rethrow;
    } on SwayvePluginException {
      // Falling through to the local clock is the right failure here: most
      // devices are close enough, and refusing to mint because the clock
      // could not be confirmed would turn a working lookup into a dead one.
    }

    _clockOffset = Duration.zero;
    return _now();
  }

  Map<String, String> _webHeaders(String cookie) => <String, String>{
        'accept': 'application/json',
        'user-agent': kSpotifyWebUserAgent,
        'origin': kSpotifyWebOrigin,
        'referer': '$kSpotifyWebOrigin/',
        'cookie': 'sp_dc=$cookie',
      };
}
