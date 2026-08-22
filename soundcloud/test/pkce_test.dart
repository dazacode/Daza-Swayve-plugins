import 'dart:convert';

import 'package:soundcloud/src/auth/pkce.dart';
import 'package:test/test.dart';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('sha256Bytes', () {
    // The standard NIST/FIPS 180-4 test vectors — the empty string, the
    // one-block "abc" example, and the two-block 56-character example that
    // exercises the multi-chunk path.
    test('the empty message', () {
      expect(
        _hex(sha256Bytes(utf8.encode(''))),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('"abc"', () {
      expect(
        _hex(sha256Bytes(utf8.encode('abc'))),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('a two-block message', () {
      expect(
        _hex(
          sha256Bytes(
            utf8.encode(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
            ),
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });
  });

  group('generateCodeVerifier', () {
    test('is 43 characters — 32 random bytes, base64url, no padding', () {
      expect(generateCodeVerifier(), hasLength(43));
    });

    test('uses only RFC 7636 unreserved characters', () {
      final RegExp unreserved = RegExp(r'^[A-Za-z0-9_-]+$');
      expect(unreserved.hasMatch(generateCodeVerifier()), isTrue);
    });

    test('two calls do not collide', () {
      expect(generateCodeVerifier(), isNot(generateCodeVerifier()));
    });
  });

  group('codeChallengeFor', () {
    // RFC 7636 Appendix B's own worked example.
    test('matches the RFC 7636 Appendix B worked example', () {
      const String verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      expect(
        codeChallengeFor(verifier),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('is deterministic for the same verifier', () {
      final String verifier = generateCodeVerifier();
      expect(codeChallengeFor(verifier), codeChallengeFor(verifier));
    });

    test('is base64url with no padding', () {
      final String challenge = codeChallengeFor(generateCodeVerifier());
      expect(challenge, isNot(contains('=')));
      expect(challenge, isNot(contains('+')));
      expect(challenge, isNot(contains('/')));
    });
  });
}
