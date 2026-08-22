/// PKCE (RFC 7636) code generation, and the SHA-256 it is built on.
///
/// ## Why SHA-256 is written out here rather than imported
///
/// This plugin adds no dependency beyond `swayve_plugin_sdk` — see the
/// "Dependencies we deliberately do not have" section of `README.md`.
/// `package:crypto` would be the obvious import, and the same discipline
/// that ruled it out for YouTube Music's SHA-1 (`auth/sapisid_hash.dart` in
/// that plugin) applies here: a plugin's dependency surface is something the
/// manifest and the permission model cannot see or enforce, so it stays
/// reviewable by staying small. SHA-256 is a few dozen lines more than
/// SHA-1, not a different category of risk.
///
/// ## Why PKCE at all
///
/// SoundCloud's own developer guide states plainly that PKCE is required for
/// the authorization code exchange, not optional hardening — a request for
/// an authorization code that omits `code_challenge`/`code_challenge_method`
/// is rejected outright. See `providers/auth_provider.dart` for where this
/// is used: a fresh [codeVerifier] is generated per sign-in attempt, never
/// reused, and never leaves this device except as the SHA-256'd
/// [codeChallengeFor] sent on the authorize request — the verifier itself is
/// sent only once, at the token exchange, over the same encrypted request
/// that carries the authorization code.
library;

import 'dart:convert';
import 'dart:math';

const int _mask32 = 0xFFFFFFFF;

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask32;

/// The first 32 bits of the fractional parts of the cube roots of the first
/// 64 primes — FIPS 180-4's SHA-256 round constants, reproduced verbatim.
const List<int> _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// Computes the raw SHA-256 digest of [message], as 32 bytes.
///
/// A textbook implementation of FIPS 180-4, the same style
/// `youtube_music/lib/src/auth/sapisid_hash.dart`'s `sha1Bytes` follows:
/// plain `List<int>` and `dart:core` integers, every intermediate 32-bit
/// value masked to [_mask32] after every arithmetic or shift operation
/// because Dart's `int` is not a wrapping 32-bit word on every compilation
/// target.
List<int> sha256Bytes(List<int> message) {
  final List<int> data = List<int>.from(message);
  final int originalBitLength = data.length * 8;

  data.add(0x80);
  while (data.length % 64 != 56) {
    data.add(0);
  }
  for (int shift = 56; shift >= 0; shift -= 8) {
    data.add((originalBitLength >> shift) & 0xff);
  }

  int h0 = 0x6a09e667;
  int h1 = 0xbb67ae85;
  int h2 = 0x3c6ef372;
  int h3 = 0xa54ff53a;
  int h4 = 0x510e527f;
  int h5 = 0x9b05688c;
  int h6 = 0x1f83d9ab;
  int h7 = 0x5be0cd19;

  for (int chunkStart = 0; chunkStart < data.length; chunkStart += 64) {
    final List<int> w = List<int>.filled(64, 0);
    for (int i = 0; i < 16; i++) {
      final int base = chunkStart + i * 4;
      w[i] = (data[base] << 24) |
          (data[base + 1] << 16) |
          (data[base + 2] << 8) |
          data[base + 3];
    }
    for (int i = 16; i < 64; i++) {
      final int s0 =
          _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final int s1 =
          _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask32;
    }

    int a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (int i = 0; i < 64; i++) {
      final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final int ch = (e & f) ^ ((~e & _mask32) & g);
      final int temp1 = (h + s1 + ch + _k[i] + w[i]) & _mask32;
      final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int temp2 = (s0 + maj) & _mask32;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & _mask32;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & _mask32;
    }

    h0 = (h0 + a) & _mask32;
    h1 = (h1 + b) & _mask32;
    h2 = (h2 + c) & _mask32;
    h3 = (h3 + d) & _mask32;
    h4 = (h4 + e) & _mask32;
    h5 = (h5 + f) & _mask32;
    h6 = (h6 + g) & _mask32;
    h7 = (h7 + h) & _mask32;
  }

  final List<int> result = <int>[];
  for (final int h in <int>[h0, h1, h2, h3, h4, h5, h6, h7]) {
    result
      ..add((h >> 24) & 0xff)
      ..add((h >> 16) & 0xff)
      ..add((h >> 8) & 0xff)
      ..add(h & 0xff);
  }
  return result;
}

final Random _secureRandom = Random.secure();

/// A fresh PKCE code verifier: 32 cryptographically random bytes,
/// base64url-encoded without padding — 43 characters, comfortably inside
/// RFC 7636's required 43-128 character range and drawn only from its
/// unreserved character set (base64url without padding already is that
/// set).
String generateCodeVerifier() {
  final List<int> bytes =
      List<int>.generate(32, (_) => _secureRandom.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

/// The `code_challenge` for [verifier] under `code_challenge_method=S256` —
/// the base64url-without-padding encoding of the verifier's own SHA-256
/// digest, per RFC 7636 §4.2.
String codeChallengeFor(String verifier) {
  final List<int> digest = sha256Bytes(utf8.encode(verifier));
  return base64Url.encode(digest).replaceAll('=', '');
}
