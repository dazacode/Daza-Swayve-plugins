/// SHA-1 and HMAC-SHA1, implemented here rather than depended on.
///
/// This plugin's pubspec has exactly one dependency, the SDK, and that is
/// deliberate: a plugin that pulls in its own packages is a plugin whose
/// supply chain the host cannot see. `package:crypto` would be the obvious
/// answer to "I need HMAC-SHA1" and it is a fine package — but the whole of
/// what is needed here is two well-specified functions over a handful of
/// bytes, and RFC 3174 and RFC 2104 have not moved since 2001. Vendoring them
/// costs less than the precedent of a second dependency would.
///
/// Used for exactly one thing: deriving the six-digit code Spotify's web
/// token endpoint demands. See `spotify_totp.dart`.
library;

/// The SHA-1 digest of [message], as 20 bytes.
List<int> sha1(List<int> message) {
  int h0 = 0x67452301;
  int h1 = 0xEFCDAB89;
  int h2 = 0x98BADCFE;
  int h3 = 0x10325476;
  int h4 = 0xC3D2E1F0;

  // RFC 3174 §4: append a single 1 bit, pad with zeroes to 56 mod 64, then
  // the original length in bits as a 64-bit big-endian integer.
  final List<int> padded = <int>[...message, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  final int bitLength = message.length * 8;
  for (int i = 7; i >= 0; i--) {
    padded.add((bitLength >> (i * 8)) & 0xFF);
  }

  final List<int> w = List<int>.filled(80, 0);
  for (int chunk = 0; chunk < padded.length; chunk += 64) {
    for (int i = 0; i < 16; i++) {
      final int j = chunk + i * 4;
      w[i] = (padded[j] << 24) |
          (padded[j + 1] << 16) |
          (padded[j + 2] << 8) |
          padded[j + 3];
    }
    for (int i = 16; i < 80; i++) {
      w[i] = _rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    int a = h0;
    int b = h1;
    int c = h2;
    int d = h3;
    int e = h4;

    for (int i = 0; i < 80; i++) {
      final int f;
      final int k;
      if (i < 20) {
        f = (b & c) | (~b & d);
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
      final int temp =
          (_rotl(a, 5) + (f & 0xFFFFFFFF) + e + k + w[i]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = _rotl(b, 30);
      b = a;
      a = temp;
    }

    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
  }

  return <int>[
    for (final int word in <int>[h0, h1, h2, h3, h4]) ...<int>[
      (word >> 24) & 0xFF,
      (word >> 16) & 0xFF,
      (word >> 8) & 0xFF,
      word & 0xFF,
    ],
  ];
}

/// The HMAC-SHA1 of [message] under [key], as 20 bytes. RFC 2104.
List<int> hmacSha1(List<int> key, List<int> message) {
  const int blockSize = 64;

  // A key longer than the block size is replaced by its own digest; a shorter
  // one is zero-padded up to it.
  final List<int> normalized = key.length > blockSize ? sha1(key) : key;
  final List<int> padded = List<int>.filled(blockSize, 0);
  for (int i = 0; i < normalized.length; i++) {
    padded[i] = normalized[i];
  }

  final List<int> inner = <int>[
    for (final int byte in padded) byte ^ 0x36,
    ...message,
  ];
  return sha1(<int>[
    for (final int byte in padded) byte ^ 0x5C,
    ...sha1(inner),
  ]);
}

/// Rotates the low 32 bits of [value] left by [bits].
int _rotl(int value, int bits) {
  final int masked = value & 0xFFFFFFFF;
  return ((masked << bits) | (masked >>> (32 - bits))) & 0xFFFFFFFF;
}
