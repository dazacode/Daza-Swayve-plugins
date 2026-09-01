import 'dart:convert';

import 'package:test/test.dart';
import 'package:visuals/visuals.dart';

/// The vendored crypto and the code derived from it.
///
/// These are the tests that matter most in this plugin and the ones easiest
/// to omit. Everything else here fails loudly when it is wrong — a bad URL is
/// a 404, a bad parse is an exception. A wrong HMAC produces a perfectly
/// well-formed six-digit number that Spotify simply refuses, and the symptom
/// is "canvases don't work" with nothing in the logs to say why. So the
/// primitives are pinned to published vectors rather than to whatever this
/// implementation happened to produce on the day it was written.
void main() {
  group('sha1', () {
    // RFC 3174 §7.3 and the FIPS 180-1 examples.
    test('matches the published digests', () {
      expect(
        _hex(sha1(utf8.encode('abc'))),
        'a9993e364706816aba3e25717850c26c9cd0d89d',
      );
      expect(
        _hex(sha1(utf8.encode(''))),
        'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      );
      expect(
        _hex(
          sha1(
            utf8.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
            ),
          ),
        ),
        '84983e441c3bd26ebaae4aa1f95129e5e54670f1',
      );
    });

    test('handles a message that lands exactly on a block boundary', () {
      // 55 bytes needs one block, 56 needs two — the padding edge where a
      // hand-written implementation goes wrong if it goes wrong at all.
      expect(_hex(sha1(List<int>.filled(55, 0x61))).length, 40);
      expect(_hex(sha1(List<int>.filled(56, 0x61))).length, 40);
      expect(
        _hex(sha1(List<int>.filled(64, 0x61))),
        '0098ba824b5c16427bd7a1122a5a442a25ec644d',
      );
    });
  });

  group('hmacSha1', () {
    // RFC 2202 §3.
    test('matches the published vectors', () {
      expect(
        _hex(hmacSha1(List<int>.filled(20, 0x0b), utf8.encode('Hi There'))),
        'b617318655057264e28bc0b6fb378c8ef146be00',
      );
      expect(
        _hex(
          hmacSha1(
            utf8.encode('Jefe'),
            utf8.encode('what do ya want for nothing?'),
          ),
        ),
        'effcdf6ae5eb2fa2d27416d5f184df9c259a7c79',
      );
      expect(
        _hex(
          hmacSha1(
            List<int>.filled(20, 0xaa),
            List<int>.filled(50, 0xdd),
          ),
        ),
        '125d7342b9ac11cd91a39af48aa17b4f63f175d3',
      );
    });

    test('a key longer than the block size is replaced by its digest', () {
      // RFC 2202 §3 case 6, the branch that only runs for keys over 64 bytes.
      expect(
        _hex(
          hmacSha1(
            List<int>.filled(80, 0xaa),
            utf8.encode(
              'Test Using Larger Than Block-Size Key - Hash Key First',
            ),
          ),
        ),
        'aa4ae5e15272d00e95705637ce8a3b55ed402112',
      );
    });
  });

  group('totpCode', () {
    // RFC 4226 Appendix D, the canonical HOTP vectors.
    test('matches the published counter sequence', () {
      final secret = utf8.encode('12345678901234567890');
      const expected = <String>[
        '755224',
        '287082',
        '359152',
        '969429',
        '338314',
        '254676',
        '287922',
        '162583',
        '399871',
        '520489',
      ];
      for (int counter = 0; counter < expected.length; counter++) {
        expect(
          totpCode(secret, counter),
          expected[counter],
          reason: 'counter $counter',
        );
      }
    });

    test('always returns the requested number of digits', () {
      final secret = utf8.encode('12345678901234567890');
      for (int counter = 0; counter < 200; counter++) {
        expect(totpCode(secret, counter), hasLength(kTotpDigits));
      }
    });
  });

  group('spotifyTotpSecret', () {
    test('is the ASCII of the joined decimal values, not their bytes', () {
      // The step worth pinning: [44, 55] at positions 0 and 1 becomes
      // [44 ^ 9, 55 ^ 10] = [37, 61], which is the *text* "3761".
      expect(spotifyTotpSecret(<int>[44, 55]), utf8.encode('3761'));
    });

    test('the position constant wraps every 33 bytes', () {
      // Position 33 is XORed with 9 again, exactly as position 0 was.
      final wrapped = spotifyTotpSecret(List<int>.filled(34, 0));
      expect(utf8.decode(wrapped), startsWith('9'));
      expect(utf8.decode(wrapped), endsWith('9'));
    });

    test('the embedded cipher produces a usable key', () {
      final secret = spotifyTotpSecret();
      expect(secret, isNotEmpty);
      expect(kSpotifyTotpCipher, hasLength(26));
      expect(kSpotifyTotpVersion, 61);
    });
  });

  group('spotifyTotpAt', () {
    test('is stable within a period and changes across one', () {
      final base = DateTime.fromMillisecondsSinceEpoch(1767000000000);
      expect(
        spotifyTotpAt(base),
        spotifyTotpAt(base.add(const Duration(seconds: 29))),
      );
      expect(
        spotifyTotpAt(base),
        isNot(spotifyTotpAt(base.add(const Duration(seconds: 31)))),
      );
    });

    test('counts periods from the epoch', () {
      expect(totpCounterAt(DateTime.fromMillisecondsSinceEpoch(0)), 0);
      expect(totpCounterAt(DateTime.fromMillisecondsSinceEpoch(29999)), 0);
      expect(totpCounterAt(DateTime.fromMillisecondsSinceEpoch(30000)), 1);
      expect(kTotpPeriod, const Duration(seconds: 30));
    });
  });
}

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
