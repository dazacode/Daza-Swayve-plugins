import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../auth/oauth_tokens.dart';
import '../auth/pkce.dart';
import '../config.dart';
import '../json_path.dart';
import '../soundcloud_client.dart';

/// SoundCloud's answer to `SwayveAuthProvider`. Capability: `authentication`,
/// permissions `external_auth` and `webview`.
///
/// ## Why this is a real OAuth flow, not a captured cookie
///
/// This plugin's public catalogue — search, charts, streaming, an artist's
/// *public* likes — talks to the scraped, anonymous `api-v2.soundcloud.com`
/// surface, the same as every other unofficial SoundCloud client. That
/// surface has no route at all for "my own liked tracks": there is no
/// anonymous concept of *me*. An earlier version of this provider tried
/// carrying a captured browser session cookie through anyway, and it does
/// not work — confirmed live, `api-v2`'s `/me` answers `401` identically
/// whether the request carries a real signed-in cookie or nothing at all,
/// because that endpoint sits behind bot-detection (DataDome) that a
/// non-browser HTTP client cannot pass regardless of how valid the
/// credential is. See git history for the full account; this plugin does
/// not attempt to defeat that protection.
///
/// The way through is the one SoundCloud actually documents: register an
/// application, run a real OAuth 2 authorization-code exchange (PKCE
/// required — see `auth/pkce.dart`), and call the *official*
/// `api.soundcloud.com`, a different host with a different bot-protection
/// posture, entirely separate from the scraped surface. Two independent,
/// actively-used open-source SoundCloud clients —
/// `soundcrowd-plugin-soundcloud` (Kotlin) and `SqueezeCloud` (Perl) — were
/// read to confirm this endpoint and header shape before writing this file.
///
/// ## Whose application this is
///
/// SoundCloud closed new developer registrations years ago (see
/// `README.md`'s "Why an unofficial API, not the official one"), so there is
/// no application this plugin could ship baked in the way
/// `soundcrowd-plugin-soundcloud` and `SqueezeCloud` each publish one shared
/// `client_id`/`client_secret` pair for anyone running their code. This
/// plugin asks for your own instead — [kClientIdSettingId] and
/// [kClientSecretSettingId], both `type: "secret"` settings pasted once into
/// the host's settings screen, never committed to this repository. If
/// SoundCloud ever reopens registration, or a shared application becomes
/// available, this is the one place that assumption would need revisiting.
///
/// ## Why [authState] never touches the network
///
/// The SDK's contract on `SwayveAuthProvider.authState` says it must not
/// "make the user wait on the network longer than necessary," and it is
/// called during host startup for every active plugin at once. This answers
/// from whether a token is stored, nothing more — a stored token that has
/// since been revoked is caught the next time [SoundCloudLibraryProvider]
/// actually uses it, the same "optimistic until proven otherwise" contract
/// the YouTube Music reference plugin's own auth provider follows.
final class SoundCloudAuthProvider implements SwayveAuthProvider {
  /// Creates a provider over [client], [credentials] and [webView].
  SoundCloudAuthProvider({
    required SoundCloudClient client,
    required SwayveCredentialStore credentials,
    required SwayveWebViewController webView,
    this.timeouts = SoundCloudTimeouts.manifest,
  })  : _client = client,
        _credentials = credentials,
        _webView = webView,
        _tokens =
            SoundCloudOAuthTokens(client: client, credentials: credentials);

  final SoundCloudClient _client;
  final SwayveCredentialStore _credentials;
  final SwayveWebViewController _webView;
  final SoundCloudOAuthTokens _tokens;

  /// The deadlines this provider works to.
  final SoundCloudTimeouts timeouts;

  final StreamController<SwayveAuthState> _changes =
      StreamController<SwayveAuthState>.broadcast();

  SwayveAuthState _state = SwayveAuthState.signedOut;

  /// Releases the stream this provider owns. See the matching comment on
  /// the YouTube Music reference plugin's own auth provider — `dispose`
  /// calls this so a broadcast controller never outlives the plugin
  /// instance that created it.
  Future<void> dispose() => _changes.close();

  void _publish(SwayveAuthState next) {
    _state = next;
    _changes.add(next);
  }

  @override
  Stream<SwayveAuthState> get authStateChanges => Stream<SwayveAuthState>.multi(
        (MultiStreamController<SwayveAuthState> controller) {
          controller.add(_state);
          final StreamSubscription<SwayveAuthState> subscription =
              _changes.stream.listen(
            controller.add,
            onError: controller.addError,
          );
          controller.onCancel = subscription.cancel;
        },
        isBroadcast: true,
      );

  @override
  Future<SwayveAuthState> authState() async {
    final bool hasSession = await _tokens.hasStoredSession();
    _publish(
      hasSession
          ? SwayveAuthState(
              status: SwayveAuthStatus.signedIn,
              accountLabel: _state.accountLabel,
            )
          : SwayveAuthState.signedOut,
    );
    return _state;
  }

  @override
  Future<SwayveAuthState> authenticate() async {
    final String? clientId = await _credentials.readSecret(
      kClientIdSettingId,
    );
    final String? clientSecret = await _credentials.readSecret(
      kClientSecretSettingId,
    );
    if (clientId == null ||
        clientId.trim().isEmpty ||
        clientSecret == null ||
        clientSecret.trim().isEmpty) {
      final SwayveAuthState failed = const SwayveAuthState(
        status: SwayveAuthStatus.failed,
        message: 'Add your own SoundCloud API client ID and client secret '
            'in Settings first — see README.md for how to register one.',
      );
      _publish(failed);
      return failed;
    }

    final String verifier = generateCodeVerifier();
    final Uri authorizeUri = kOAuthAuthorizeUri.replace(
      queryParameters: <String, String>{
        'client_id': clientId,
        'redirect_uri': kOAuthRedirectUri,
        'response_type': 'code',
        'code_challenge': codeChallengeFor(verifier),
        'code_challenge_method': 'S256',
      },
    );
    final Uri redirect = Uri.parse(kOAuthRedirectUri);

    final Uri? completion;
    try {
      completion = await _webView.presentForResult(
        authorizeUri,
        isComplete: (Uri url) =>
            url.host == redirect.host && url.path == redirect.path,
        timeout: timeouts.operation,
      );
    } on SwayvePluginException catch (error) {
      final SwayveAuthState failed = SwayveAuthState(
        status: SwayveAuthStatus.failed,
        message: 'Could not open the SoundCloud sign-in page '
            '(${error.code}).',
      );
      _publish(failed);
      return failed;
    }

    if (completion == null) {
      final SwayveAuthState failed = const SwayveAuthState(
        status: SwayveAuthStatus.failed,
        message: 'Sign-in was cancelled.',
      );
      _publish(failed);
      return failed;
    }

    final String? deniedReason = completion.queryParameters['error'];
    if (deniedReason != null) {
      final SwayveAuthState failed = SwayveAuthState(
        status: SwayveAuthStatus.failed,
        message: 'SoundCloud did not complete sign-in ($deniedReason).',
      );
      _publish(failed);
      return failed;
    }
    final String? code = completion.queryParameters['code'];
    if (code == null || code.isEmpty) {
      final SwayveAuthState failed = const SwayveAuthState(
        status: SwayveAuthStatus.failed,
        message: 'SoundCloud did not return an authorization code.',
      );
      _publish(failed);
      return failed;
    }

    try {
      final Map<String, Object?> tokenResponse = await _client
          .exchangeAuthorizationCode(
            clientId: clientId,
            clientSecret: clientSecret,
            code: code,
            codeVerifier: verifier,
          )
          .timeout(timeouts.operation);
      await _tokens.store(tokenResponse);
    } on SwayvePluginException catch (error) {
      final SwayveAuthState failed = SwayveAuthState(
        status: SwayveAuthStatus.failed,
        message: 'Could not complete SoundCloud sign-in (${error.code}).',
      );
      _publish(failed);
      return failed;
    } on TimeoutException {
      final SwayveAuthState failed = const SwayveAuthState(
        status: SwayveAuthStatus.failed,
        message: 'SoundCloud took too long to answer. Try again.',
      );
      _publish(failed);
      return failed;
    }

    // Best-effort account label — sign-in has already succeeded by this
    // point (a token pair is stored), so a failure here degrades to a
    // nameless "Connected" rather than undoing the sign-in.
    String? handle;
    try {
      final String accessToken = await _tokens.validAccessToken(
        clientId: clientId,
        clientSecret: clientSecret,
      );
      final Map<String, Object?>? me = await _client
          .officialMe(accessToken: accessToken)
          .timeout(timeouts.operation);
      handle = me == null ? null : stringAt(me, const <Object>['username']);
    } catch (_) {
      // See above — nameless "Connected" is still a truthful signed-in
      // state.
    }

    final SwayveAuthState signedIn = SwayveAuthState(
      status: SwayveAuthStatus.signedIn,
      accountLabel: handle,
    );
    _publish(signedIn);
    return signedIn;
  }

  @override
  Future<void> signOut() async {
    try {
      await _tokens.clear();
    } catch (_) {
      // The contract is unconditional ("must succeed even when the network
      // is unreachable") — whatever went wrong in the store is not this
      // method's to surface. `client_id`/`client_secret` are deliberately
      // left alone: they are the user's own registered application, not
      // part of this session, and re-signing in should not require pasting
      // them again.
    } finally {
      _publish(SwayveAuthState.signedOut);
    }
  }
}
