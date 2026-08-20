/// A dependency-free SHA-1 implementation, and the `SAPISIDHASH`
/// `Authorization` header InnerTube expects on a cookie-authenticated
/// request.
///
/// ## Why SHA-1 is written out here rather than imported
///
/// This plugin adds no dependency beyond `swayve_plugin_sdk` — see the
/// "Dependencies we deliberately do not have" section of `README.md`, which
/// already rejected four packages on the grounds that a plugin's dependency
/// surface is something the manifest and the permission model cannot see or
/// enforce, so it stays reviewable by staying small. `package:crypto` has no
/// transport of its own and would not reintroduce the specific hole that
/// section is about, but the same discipline applies, and SHA-1 is under a
/// hundred lines. Written here instead of added as a package.
///
/// ## What `SAPISIDHASH` is, and the honesty note that belongs beside it
///
/// `SAPISIDHASH` is the scheme several Google web properties use to
/// authenticate a same-origin request using only a cookie, without a full
/// OAuth token: ``Authorization: SAPISIDHASH {ts}_{sha1("{ts} {sapisid}
/// {origin}")}``. It is not published by Google as a stable API; it is
/// reverse-engineered behaviour reproduced by essentially every unofficial
/// YouTube Music client. The implementation below follows that
/// widely-documented pattern as best understood from public prior art, but it
/// has **not** been exercised against a real, signed-in `music.youtube.com`
/// session — there is no live account available to verify it against here.
/// See `providers/auth_provider.dart` and the change that introduced this
/// file for the explicit flag: this needs live-account verification before
/// shipping. [sha1Bytes] itself is verified against the standard NIST test
/// vectors in `test/sapisid_hash_test.dart`, so if authentication ever fails
/// against a real account, the SHA-1 primitive is the least likely culprit —
/// look at the header assembly and the cookie names read instead.
library;

import 'dart:convert';

const int _mask32 = 0xFFFFFFFF;

int _rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & _mask32;

/// Computes the raw SHA-1 digest of [message], as 20 bytes.
///
/// A textbook implementation of FIPS 180-4, operating only on `List<int>` and
/// `dart:core` integers — no `dart:typed_data` tricks, so it stays exactly as
/// portable as the rest of this pure-Dart plugin. Every intermediate 32-bit
/// value is masked to `_mask32` after every arithmetic or shift operation,
/// because Dart's `int` is 64-bit (or an unbounded `BigInt`-backed value on
/// some web compilation targets) rather than the wrapping 32-bit word the
/// algorithm assumes.
List<int> sha1Bytes(List<int> message) {
  final List<int> data = List<int>.from(message);
  final int originalBitLength = data.length * 8;

  data.add(0x80);
  while (data.length % 64 != 56) {
    data.add(0);
  }
  // The 64-bit big-endian bit length. Every message this plugin ever hashes
  // is a short header string, far short of 2^32 bits, so the high 32 bits
  // are always zero — written out anyway so this is a correct, general SHA-1
  // rather than one that only happens to work for short inputs.
  for (int shift = 56; shift >= 0; shift -= 8) {
    data.add((originalBitLength >> shift) & 0xff);
  }

  int h0 = 0x67452301;
  int h1 = 0xEFCDAB89;
  int h2 = 0x98BADCFE;
  int h3 = 0x10325476;
  int h4 = 0xC3D2E1F0;

  for (int chunkStart = 0; chunkStart < data.length; chunkStart += 64) {
    final List<int> w = List<int>.filled(80, 0);
    for (int i = 0; i < 16; i++) {
      final int base = chunkStart + i * 4;
      w[i] = (data[base] << 24) |
          (data[base + 1] << 16) |
          (data[base + 2] << 8) |
          data[base + 3];
    }
    for (int i = 16; i < 80; i++) {
      w[i] = _rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    int a = h0, b = h1, c = h2, d = h3, e = h4;
    for (int i = 0; i < 80; i++) {
      final int f;
      final int k;
      if (i < 20) {
        f = (b & c) | ((~b & _mask32) & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final int temp = (_rotl(a, 5) + f + e + k + w[i]) & _mask32;
      e = d;
      d = c;
      c = _rotl(b, 30);
      b = a;
      a = temp;
    }

    h0 = (h0 + a) & _mask32;
    h1 = (h1 + b) & _mask32;
    h2 = (h2 + c) & _mask32;
    h3 = (h3 + d) & _mask32;
    h4 = (h4 + e) & _mask32;
  }

  final List<int> result = <int>[];
  for (final int h in <int>[h0, h1, h2, h3, h4]) {
    result
      ..add((h >> 24) & 0xff)
      ..add((h >> 16) & 0xff)
      ..add((h >> 8) & 0xff)
      ..add(h & 0xff);
  }
  return result;
}

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Computes an InnerTube `SAPISIDHASH` `Authorization` header value from a
/// raw `Cookie` header string, or `null` when it carries no cookie this
/// scheme can be computed from.
///
/// Reads `__Secure-3PAPISID` first and falls back to plain `SAPISID`. Both
/// are copies of the same secret Google's sign-in sets; browsers expose the
/// `__Secure-3PAPISID` cookie to cross-site requests and the plain one only
/// to same-site requests, and the unofficial clients this plugin's approach
/// follows read the `__Secure-3PAPISID` copy first for that reason — see the
/// library comment for how confident that reading is.
///
/// [now] exists for tests; real callers leave it as the current time.
String? sapisidHashAuthorization(
  String cookieHeader,
  String origin, {
  DateTime? now,
}) {
  final String? sapisid = _cookieValue(cookieHeader, '__Secure-3PAPISID') ??
      _cookieValue(cookieHeader, 'SAPISID');
  if (sapisid == null || sapisid.isEmpty) return null;

  final int timestamp =
      (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
  final String digest =
      _hex(sha1Bytes(utf8.encode('$timestamp $sapisid $origin')));
  return 'SAPISIDHASH ${timestamp}_$digest';
}

/// The value of cookie [name] within [cookieHeader], or `null` when it is not
/// present.
///
/// [cookieHeader] is a `; `-joined `name=value` list, the shape of a raw
/// `Cookie` header — which is exactly what a person pastes out of their
/// browser's devtools for this setting. Matching is on the name before the
/// first `=`, so a value that itself contains `=` (a base64-ish cookie value
/// often does) is read whole rather than truncated.
String? _cookieValue(String cookieHeader, String name) {
  for (final String part in cookieHeader.split(';')) {
    final String trimmed = part.trim();
    final int eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    if (trimmed.substring(0, eq) == name) {
      return trimmed.substring(eq + 1);
    }
  }
  return null;
}
