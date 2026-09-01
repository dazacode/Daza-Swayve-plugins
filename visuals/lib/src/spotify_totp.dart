/// The six-digit code Spotify's web token endpoint demands.
///
/// ## Why a plugin is computing a TOTP at all
///
/// `open.spotify.com/api/token` used to hand back an access token for any
/// request carrying an `sp_dc` cookie. It now also requires a time-based
/// one-time code, derived from a secret the web player ships inside its own
/// bundle. The secret is not a per-user credential and grants nothing on its
/// own — it is a shared constant every copy of the web player holds, and its
/// only purpose is to make a request look like it came from the web player.
///
/// ## Why the version is embedded rather than fetched
///
/// The obvious implementation downloads the current secret from one of the
/// community-maintained mirrors at startup. Spotify had the best-known of
/// those mirrors taken down in early 2026, which broke every client that
/// depended on it at once — including the API this plugin's approach was
/// first sketched against. It is back, and that is precisely the problem: a
/// third-party repository that can vanish and reappear is not something a
/// music player should need reachable in order to draw a background.
///
/// So the version this plugin knows about is a constant in the source, and a
/// person can override it from settings without waiting for a release if
/// Spotify ever rotates again. Nothing is fetched at runtime.
///
/// ## What happens when it goes stale
///
/// Nothing dramatic, by design. A rejected token makes
/// `SpotifyCanvasVisualsSource` return null, the provider falls through to
/// the TIDAL sources behind it, and the now-playing screen shows whatever it
/// would have shown anyway. A canvas is scenery; losing it is a smaller event
/// than an error dialog would imply.
library;

import 'dart:convert';

import 'hmac_sha1.dart';

/// The TOTP secret version this plugin embeds.
///
/// Spotify publishes a numbered secret with each web-player release and its
/// requests name the version they used. v61 was first seen in January 2026
/// and is what the web player still selects.
const int kSpotifyTotpVersion = 61;

/// The cipher bytes for [kSpotifyTotpVersion].
///
/// Not a secret belonging to anybody and not a credential: this is a constant
/// compiled into the public web player, identical for every user, and it
/// grants no account access by itself. The `sp_dc` cookie is the credential;
/// this only shapes the request around it.
const List<int> kSpotifyTotpCipher = <int>[
  44,
  55,
  47,
  42,
  70,
  40,
  34,
  114,
  76,
  74,
  50,
  111,
  120,
  97,
  75,
  76,
  94,
  102,
  43,
  69,
  49,
  120,
  118,
  80,
  64,
  78,
];

/// How long one code is valid, and therefore the width of a counter step.
const Duration kTotpPeriod = Duration(seconds: 30);

/// The number of digits in a generated code.
const int kTotpDigits = 6;

/// Turns [cipher] into the HMAC key the TOTP is computed under.
///
/// The transformation is the web player's own and looks arbitrary because it
/// is: each byte is XORed with a position-dependent constant, the results are
/// written out as decimal numbers, and the resulting *text* is the key. The
/// last step is the surprising one — the key is the ASCII of a digit string,
/// not the bytes those digits denote.
List<int> spotifyTotpSecret([List<int> cipher = kSpotifyTotpCipher]) {
  final StringBuffer joined = StringBuffer();
  for (int i = 0; i < cipher.length; i++) {
    joined.write(cipher[i] ^ ((i % 33) + 9));
  }
  return utf8.encode(joined.toString());
}

/// The code for the counter step [counter], under [secret].
///
/// RFC 4226 dynamic truncation over an 8-byte big-endian counter.
String totpCode(
  List<int> secret,
  int counter, {
  int digits = kTotpDigits,
}) {
  final List<int> message = List<int>.filled(8, 0);
  int remaining = counter;
  for (int i = 7; i >= 0; i--) {
    message[i] = remaining & 0xFF;
    remaining >>= 8;
  }

  final List<int> digest = hmacSha1(secret, message);
  final int offset = digest[digest.length - 1] & 0x0F;
  final int binary = ((digest[offset] & 0x7F) << 24) |
      ((digest[offset + 1] & 0xFF) << 16) |
      ((digest[offset + 2] & 0xFF) << 8) |
      (digest[offset + 3] & 0xFF);

  int modulus = 1;
  for (int i = 0; i < digits; i++) {
    modulus *= 10;
  }
  return (binary % modulus).toString().padLeft(digits, '0');
}

/// The counter step covering [time].
int totpCounterAt(DateTime time) =>
    time.millisecondsSinceEpoch ~/ kTotpPeriod.inMilliseconds;

/// The code Spotify expects for [time], under [cipher].
String spotifyTotpAt(DateTime time, {List<int> cipher = kSpotifyTotpCipher}) =>
    totpCode(spotifyTotpSecret(cipher), totpCounterAt(time));
