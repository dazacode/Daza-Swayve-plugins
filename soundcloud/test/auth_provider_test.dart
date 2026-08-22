import 'dart:async';

import 'package:soundcloud/soundcloud.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// `SoundCloudAuthProvider` — capability `authentication`, the real OAuth
/// authorization-code flow.
void main() {
  late PluginHarness harness;

  setUp(() async {
    harness = await PluginHarness.start(timeouts: fastTimeouts);
  });

  tearDown(() => harness.stop());

  Future<void> configureApp() async {
    await harness.credentials.writeSecret(kClientIdSettingId, 'fake-client-id');
    await harness.credentials.writeSecret(
      kClientSecretSettingId,
      'fake-client-secret',
    );
  }

  group('authState', () {
    test('no stored session is signed out', () async {
      final SwayveAuthState state = await harness.auth.authState();
      expect(state.status, SwayveAuthStatus.signedOut);
      expect(harness.http.requests, isEmpty);
    });

    test(
        'a stored access token is read as signed in without touching the '
        'network', () async {
      await harness.credentials.writeSecret(
        'oauth_access_token',
        'stored-token',
      );
      final SwayveAuthState state = await harness.auth.authState();
      expect(state.status, SwayveAuthStatus.signedIn);
      expect(harness.http.requests, isEmpty);
    });
  });

  group('authenticate — not configured', () {
    test('fails without presenting a web view when no app is configured',
        () async {
      final SwayveAuthState state = await harness.auth.authenticate();
      expect(state.status, SwayveAuthStatus.failed);
      expect(state.message, contains('client'));
      expect(harness.webView.presentations, isEmpty);
      expect(harness.http.requests, isEmpty);
    });
  });

  group('authenticate — configured', () {
    setUp(configureApp);

    test('a completed flow signs in and stores the token pair', () async {
      harness.webView.enqueueNavigation([
        Uri.parse(
          '$kOAuthRedirectUri?code=fake-auth-code&state=irrelevant',
        ),
      ]);
      harness.http
        ..enqueueJson(fixture('oauth_token.json'))
        ..enqueueJson(fixture('official_me.json'));

      final SwayveAuthState state = await harness.auth.authenticate();

      expect(state.status, SwayveAuthStatus.signedIn);
      expect(state.accountLabel, 'signed-in-listener');
      expect(
        await harness.credentials.readSecret('oauth_access_token'),
        'fake-access-token-abc123',
      );
      expect(
        await harness.credentials.readSecret('oauth_refresh_token'),
        'fake-refresh-token-def456',
      );
    });

    test('the authorize URL carries PKCE and the app credentials', () async {
      harness.webView.enqueueNavigation([
        Uri.parse('$kOAuthRedirectUri?code=fake-auth-code'),
      ]);
      harness.http
        ..enqueueJson(fixture('oauth_token.json'))
        ..enqueueJson(fixture('official_me.json'));

      await harness.auth.authenticate();

      final Uri presented = harness.webView.presentations.single.start;
      expect(presented.host, kOAuthAuthorizeUri.host);
      expect(presented.queryParameters['client_id'], 'fake-client-id');
      expect(presented.queryParameters['redirect_uri'], kOAuthRedirectUri);
      expect(presented.queryParameters['response_type'], 'code');
      expect(presented.queryParameters['code_challenge_method'], 'S256');
      expect(presented.queryParameters['code_challenge'], isNotEmpty);
    });

    test(
        'the token exchange carries the code, the app credentials and the '
        'PKCE verifier', () async {
      harness.webView.enqueueNavigation([
        Uri.parse('$kOAuthRedirectUri?code=fake-auth-code'),
      ]);
      harness.http
        ..enqueueJson(fixture('oauth_token.json'))
        ..enqueueJson(fixture('official_me.json'));

      await harness.auth.authenticate();

      final String body = harness.http.requests.first.body as String;
      expect(body, contains('grant_type=authorization_code'));
      expect(body, contains('client_id=fake-client-id'));
      expect(body, contains('client_secret=fake-client-secret'));
      expect(body, contains('code=fake-auth-code'));
      expect(body, contains('code_verifier='));
      expect(
        harness.http.requests.first.url.host,
        kOAuthTokenUri.host,
      );
    });

    test('a sign-in that never gets an account label still signs in', () async {
      harness.webView.enqueueNavigation([
        Uri.parse('$kOAuthRedirectUri?code=fake-auth-code'),
      ]);
      harness.http
        ..enqueueJson(fixture('oauth_token.json'))
        ..enqueueResponse(const SwayveHttpResponse(statusCode: 500));

      final SwayveAuthState state = await harness.auth.authenticate();
      expect(state.status, SwayveAuthStatus.signedIn);
      expect(state.accountLabel, isNull);
    });

    test('a dismissed web view fails without a token exchange', () async {
      harness.webView.enqueueDismissal();

      final SwayveAuthState state = await harness.auth.authenticate();
      expect(state.status, SwayveAuthStatus.failed);
      expect(state.message, contains('cancelled'));
      expect(harness.http.requests, isEmpty);
    });

    test('a redirect carrying an error fails with SoundCloud\'s own reason',
        () async {
      harness.webView.enqueueNavigation([
        Uri.parse('$kOAuthRedirectUri?error=access_denied'),
      ]);

      final SwayveAuthState state = await harness.auth.authenticate();
      expect(state.status, SwayveAuthStatus.failed);
      expect(state.message, contains('access_denied'));
      expect(harness.http.requests, isEmpty);
    });

    test('a redirect with neither a code nor an error fails cleanly', () async {
      harness.webView.enqueueNavigation([Uri.parse(kOAuthRedirectUri)]);

      final SwayveAuthState state = await harness.auth.authenticate();
      expect(state.status, SwayveAuthStatus.failed);
      expect(state.message, contains('authorization code'));
      expect(harness.http.requests, isEmpty);
    });

    test('a rejected token exchange fails, not throws', () async {
      harness.webView.enqueueNavigation([
        Uri.parse('$kOAuthRedirectUri?code=fake-auth-code'),
      ]);
      harness.http.enqueueResponse(
        SwayveHttpResponse.json(
          <String, Object?>{'error': 'invalid_grant'},
          statusCode: 401,
        ),
      );

      final SwayveAuthState state = await harness.auth.authenticate();
      expect(state.status, SwayveAuthStatus.failed);
      expect(state.message, isNotNull);
    });
  });

  group('signOut', () {
    test('clears the token pair but leaves the app credentials alone',
        () async {
      await configureApp();
      await harness.credentials.writeSecret(
        'oauth_access_token',
        'stored-token',
      );
      await harness.credentials.writeSecret(
        'oauth_refresh_token',
        'stored-refresh',
      );

      await harness.auth.signOut();

      expect(
        await harness.credentials.readSecret('oauth_access_token'),
        isNull,
      );
      expect(
        await harness.credentials.readSecret('oauth_refresh_token'),
        isNull,
      );
      expect(
        await harness.credentials.readSecret(kClientIdSettingId),
        'fake-client-id',
        reason: "signing out is not the same as un-registering the user's "
            'own app.',
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
        'oauth_access_token',
        'stored-token',
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
        'oauth_access_token',
        'stored-token',
      );
      await harness.auth.authState();
      await harness.auth.signOut();

      await Future<void>.delayed(Duration.zero);

      expect(
        seen,
        containsAllInOrder(<SwayveAuthStatus>[
          SwayveAuthStatus.signedOut,
          SwayveAuthStatus.signedIn,
          SwayveAuthStatus.signedOut,
        ]),
      );
    });
  });
}
