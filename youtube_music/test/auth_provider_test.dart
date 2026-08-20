import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';
import 'package:youtube_music/youtube_music.dart';

import 'support.dart';

/// `YouTubeMusicAuthProvider` — capability `authentication`.
void main() {
  late PluginHarness harness;

  setUp(() async {
    harness = await PluginHarness.start();
  });

  tearDown(() => harness.stop());

  group('authState', () {
    test('no stored cookie is signed out', () async {
      final SwayveAuthState state = await harness.auth.authState();
      expect(state.status, SwayveAuthStatus.signedOut);
      expect(harness.http.requests, isEmpty);
    });

    test('a stored cookie is read as signed in without touching the network',
        () async {
      await harness.credentials.writeSecret(
        kSessionCookieSettingId,
        'SID=abc; __Secure-3PAPISID=secret',
      );
      final SwayveAuthState state = await harness.auth.authState();
      expect(state.status, SwayveAuthStatus.signedIn);
      expect(
        harness.http.requests,
        isEmpty,
        reason: 'authState must be cheap: no round trip, ever.',
      );
    });

    test('an empty stored cookie is signed out', () async {
      await harness.credentials.writeSecret(kSessionCookieSettingId, '');
      final SwayveAuthState state = await harness.auth.authState();
      expect(state.status, SwayveAuthStatus.signedOut);
    });
  });

  group('authenticate', () {
    test('no stored cookie fails without making a request', () async {
      final SwayveAuthState state = await harness.auth.authenticate();
      expect(state.status, SwayveAuthStatus.failed);
      expect(state.message, isNotNull);
      expect(harness.http.requests, isEmpty);
    });

    test('a cookie InnerTube answers for becomes signed in', () async {
      await harness.credentials.writeSecret(
        kSessionCookieSettingId,
        'SID=abc; __Secure-3PAPISID=secret',
      );
      harness.http.enqueueJson(fixture('liked_music.json'));
      final SwayveAuthState state = await harness.auth.authenticate();
      expect(state.status, SwayveAuthStatus.signedIn);

      final RecordedHttpRequest request = harness.http.lastRequest!;
      expect(request.headers['cookie'], isNotNull);
      expect(request.headers['authorization'], startsWith('SAPISIDHASH '));
    });

    test('a rejected request becomes failed, not thrown', () async {
      await harness.credentials.writeSecret(
        kSessionCookieSettingId,
        'SID=abc; __Secure-3PAPISID=secret',
      );
      harness.http.enqueueResponse(
        SwayveHttpResponse.text('Forbidden', statusCode: 403),
      );
      final SwayveAuthState state = await harness.auth.authenticate();
      expect(state.status, SwayveAuthStatus.failed);
      expect(state.message, isNotNull);
    });

    test('a malformed response becomes failed, not thrown', () async {
      await harness.credentials.writeSecret(
        kSessionCookieSettingId,
        'SID=abc; __Secure-3PAPISID=secret',
      );
      harness.http.enqueueJson(<String, Object?>{'unexpected': true});
      final SwayveAuthState state = await harness.auth.authenticate();
      expect(state.status, SwayveAuthStatus.failed);
    });

    test('a validated cookie is reused by a later authState call', () async {
      await harness.credentials.writeSecret(
        kSessionCookieSettingId,
        'SID=abc; __Secure-3PAPISID=secret',
      );
      harness.http.enqueueJson(fixture('liked_music.json'));
      await harness.auth.authenticate();
      expect(harness.http.requests, hasLength(1));

      final SwayveAuthState state = await harness.auth.authState();
      expect(state.status, SwayveAuthStatus.signedIn);
      expect(
        harness.http.requests,
        hasLength(1),
        reason: 'authState reused the result authenticate already proved '
            'for this exact cookie, rather than asking again.',
      );
    });
  });

  group('signOut', () {
    test('deletes the stored secret and reports signed out', () async {
      await harness.credentials.writeSecret(
        kSessionCookieSettingId,
        'SID=abc; __Secure-3PAPISID=secret',
      );
      await harness.auth.signOut();

      expect(
        await harness.credentials.readSecret(kSessionCookieSettingId),
        isNull,
      );
      final SwayveAuthState state = await harness.auth.authState();
      expect(state.status, SwayveAuthStatus.signedOut);
    });

    test('never throws, even with nothing stored', () async {
      await expectLater(harness.auth.signOut(), completes);
    });
  });

  group('authStateChanges', () {
    test('a new listener is sent the current state immediately', () async {
      await harness.credentials.writeSecret(
        kSessionCookieSettingId,
        'SID=abc; __Secure-3PAPISID=secret',
      );
      await harness.auth.authState();

      final SwayveAuthState first = await harness.auth.authStateChanges.first;
      expect(first.status, SwayveAuthStatus.signedIn);
    });

    test('is a broadcast stream', () {
      expect(harness.auth.authStateChanges.isBroadcast, isTrue);
    });

    test('publishes every subsequent change to an existing listener', () async {
      final List<SwayveAuthStatus> seen = <SwayveAuthStatus>[];
      final StreamSubscription<SwayveAuthState> subscription =
          harness.auth.authStateChanges.listen(
        (SwayveAuthState state) => seen.add(state.status),
      );
      addTearDown(subscription.cancel);

      await harness.credentials.writeSecret(
        kSessionCookieSettingId,
        'SID=abc; __Secure-3PAPISID=secret',
      );
      await harness.auth.authState();
      await harness.auth.signOut();

      // Pump the event loop so the broadcast stream's async delivery lands.
      await Future<void>.delayed(Duration.zero);

      expect(
        seen,
        containsAllInOrder(<SwayveAuthStatus>[
          SwayveAuthStatus.signedOut, // The initial state, sent on listen.
          SwayveAuthStatus.signedIn, // From authState().
          SwayveAuthStatus.signedOut, // From signOut().
        ]),
      );
    });
  });
}
