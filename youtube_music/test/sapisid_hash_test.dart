import 'dart:convert';

import 'package:test/test.dart';
import 'package:youtube_music/youtube_music.dart';

/// Proves the SHA-1 primitive `auth/sapisid_hash.dart` writes out by hand
/// against standard test vectors, and proves the `SAPISIDHASH` header it
/// builds on top has the right shape and reads the right cookie.
///
/// What this file cannot prove — see the doc comment on
/// `auth/sapisid_hash.dart` — is that InnerTube actually accepts a header
/// computed this way. That needs a real, signed-in `music.youtube.com`
/// session, which nothing in this offline suite has.
void main() {
  group('sha1Bytes', () {
    String hex(List<int> bytes) =>
        bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

    test('the empty string', () {
      expect(
        hex(sha1Bytes(utf8.encode(''))),
        'da39a3ee5e6b4b0d3255bfef95601890afd80709',
      );
    });

    test('"abc", the standard one-block vector', () {
      expect(
        hex(sha1Bytes(utf8.encode('abc'))),
        'a9993e364706816aba3e25717850c26c9cd0d89d',
      );
    });

    test('"The quick brown fox..."', () {
      expect(
        hex(
          sha1Bytes(
            utf8.encode('The quick brown fox jumps over the lazy dog'),
          ),
        ),
        '2fd4e1c67a2d28fced849ee1bb76e7391b93eb12',
      );
    });

    test('a message spanning multiple 512-bit blocks', () {
      // 130 ASCII bytes needs three 64-byte blocks once the padding and the
      // 64-bit length field are added, which is what this test exists to
      // exercise: chaining `h0..h4` correctly from one block into the next.
      // The expected digest below was computed independently with the
      // system `sha1sum`, not derived from this implementation.
      expect(
        hex(sha1Bytes(utf8.encode('x' * 130))),
        'd140171ce524e232cc2a6bf07cca693c533d73a1',
      );
    });
  });

  group('sapisidHashAuthorization', () {
    final DateTime fixedNow = DateTime.utc(2026, 1, 1);
    final int fixedTimestamp = fixedNow.millisecondsSinceEpoch ~/ 1000;

    test('reads __Secure-3PAPISID ahead of SAPISID', () {
      final String? header = sapisidHashAuthorization(
        'SID=abc; SAPISID=plain-value; __Secure-3PAPISID=secure-value',
        'https://music.youtube.com',
        now: fixedNow,
      );
      expect(header, isNotNull);
      final String expectedDigest = _hexSha1(
        '$fixedTimestamp secure-value https://music.youtube.com',
      );
      expect(header, 'SAPISIDHASH ${fixedTimestamp}_$expectedDigest');
    });

    test('falls back to SAPISID when there is no __Secure-3PAPISID', () {
      final String? header = sapisidHashAuthorization(
        'SID=abc; SAPISID=plain-value',
        'https://music.youtube.com',
        now: fixedNow,
      );
      final String expectedDigest = _hexSha1(
        '$fixedTimestamp plain-value https://music.youtube.com',
      );
      expect(header, 'SAPISIDHASH ${fixedTimestamp}_$expectedDigest');
    });

    test('is null when neither cookie is present', () {
      expect(
        sapisidHashAuthorization('SID=abc; HSID=def', 'https://music.youtube.com'),
        isNull,
      );
    });

    test('a cookie value containing "=" is read whole', () {
      final String? header = sapisidHashAuthorization(
        'SAPISID=abc=def==',
        'https://music.youtube.com',
        now: fixedNow,
      );
      final String expectedDigest = _hexSha1(
        '$fixedTimestamp abc=def== https://music.youtube.com',
      );
      expect(header, 'SAPISIDHASH ${fixedTimestamp}_$expectedDigest');
    });
  });
}

String _hexSha1(String input) => sha1Bytes(utf8.encode(input))
    .map((int b) => b.toRadixString(16).padLeft(2, '0'))
    .join();
