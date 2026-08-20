import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../innertube_client.dart';
import '../parsing/feed_parser.dart';

/// YouTube Music's answer to `SwayveAuthProvider`. Capability:
/// `authentication`, permission `external_auth`.
///
/// ## What "signed in" means here
///
/// There is no OAuth surface for a user's own YouTube Music library — liked
/// songs have no public API at all, only the InnerTube session every
/// `music.youtube.com` tab already carries. The credential this provider
/// manages is therefore not a token this plugin obtained through a flow, but
/// the session cookie the user pastes by hand into the `session_cookie`
/// setting (a `type: "secret"` setting — see `plugin.json`), which the host
/// writes straight to the credential store and this provider only ever reads
/// back with `context.credentials.readSecret`. [authenticate] never opens a
/// web view: there is nothing here for `SwayvePluginContext.webView` to do.
///
/// ## Why [authState] never touches the network
///
/// The SDK's contract on `SwayveAuthProvider.authState` says it must not
/// "make the user wait on the network longer than necessary", and it is
/// called during host startup — for every active plugin, all at once, on the
/// path a person is staring at a splash screen for. Reading a local secret is
/// cheap; proving over the network that the cookie still works is not. So
/// [authState] answers what it can tell for free — a cookie is stored, or it
/// is not — and reuses the last [authenticate] result when the stored cookie
/// has not changed since. Only [authenticate] ever pays for a request.
///
/// ## Never logged
///
/// Nothing in this file calls `context.log` with the cookie, a header built
/// from it, or any exception message that could carry one. See
/// `docs/permissions.md`'s "Tokens and logs" section: the host's own
/// redaction is a safety net, not something this plugin relies on.
final class YouTubeMusicAuthProvider implements SwayveAuthProvider {
  /// Creates a provider over [client] and [credentials].
  YouTubeMusicAuthProvider({
    required InnerTubeClient client,
    required SwayveCredentialStore credentials,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  })  : _client = client,
        _credentials = credentials;

  final InnerTubeClient _client;
  final SwayveCredentialStore _credentials;

  /// The deadlines this provider works to.
  final YouTubeMusicTimeouts timeouts;

  final StreamController<SwayveAuthState> _changes =
      StreamController<SwayveAuthState>.broadcast();

  SwayveAuthState _state = SwayveAuthState.signedOut;

  /// The cookie [authenticate] last proved was good, and the state that
  /// proved it — reused by [authState] as long as the stored cookie has not
  /// changed, so a startup check never re-pays for a request [authenticate]
  /// already made.
  String? _validatedCookie;
  SwayveAuthState? _validatedState;

  /// Releases the stream this provider owns.
  ///
  /// Not part of `SwayveAuthProvider` — the SDK has no teardown hook on it —
  /// but `YouTubeMusicPlugin.dispose` calls it anyway so a broadcast
  /// controller never outlives the plugin instance that created it.
  Future<void> dispose() => _changes.close();

  void _publish(SwayveAuthState next) {
    _state = next;
    _changes.add(next);
  }

  @override
  Stream<SwayveAuthState> get authStateChanges =>
      Stream<SwayveAuthState>.multi(
        (MultiStreamController<SwayveAuthState> controller) {
          // Every new listener gets the current state immediately — the
          // contract asks for this — and then whatever this provider
          // publishes afterwards. `Stream.multi` runs this callback once per
          // subscriber, which a plain broadcast `StreamController` cannot do
          // on its own: its `onListen` only fires on the very first
          // subscriber, not on every one that comes later.
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
    final String? cookie = await _credentials.readSecret(
      kSessionCookieSettingId,
    );
    if (cookie == null || cookie.trim().isEmpty) {
      _validatedCookie = null;
      _validatedState = null;
      _publish(SwayveAuthState.signedOut);
      return _state;
    }
    if (cookie == _validatedCookie && _validatedState != null) {
      _publish(_validatedState!);
      return _state;
    }
    // A cookie is stored but has not been proven good in this run — most
    // often because the plugin just started and nothing has called
    // `authenticate` yet. Reporting `signedIn` optimistically, rather than
    // `signedOut`, is what lets a host that restores a plugin at app start
    // show "connected" immediately instead of a false sign-in prompt; if the
    // cookie has actually gone stale, the first real call surfaces that —
    // `likedTracks` throwing `SwayvePluginAuthRequiredException`, or a later
    // `authenticate`.
    _publish(
      SwayveAuthState(
        status: SwayveAuthStatus.signedIn,
        accountLabel: _state.accountLabel,
      ),
    );
    return _state;
  }

  @override
  Future<SwayveAuthState> authenticate() async {
    final String? cookie = await _credentials.readSecret(
      kSessionCookieSettingId,
    );
    if (cookie == null || cookie.trim().isEmpty) {
      final SwayveAuthState failed = const SwayveAuthState(
        status: SwayveAuthStatus.failed,
        message: 'No YouTube Music session cookie has been saved yet.',
      );
      _publish(failed);
      return failed;
    }

    try {
      final Map<String, Object?> body = await _client
          .browse(YouTubeMusicFeeds.likedSongs, sessionCookie: cookie)
          .timeout(timeouts.operation);
      // A parseable feed — even an empty one, for someone who has liked
      // nothing yet — is what a valid, signed-in session answers with.
      // `tryParseFeed` rather than `parseFeed`: a response this plugin
      // cannot make sense of at all is a reason to report "could not
      // verify", not to throw out of a method the SDK says should not throw
      // for a bad credential.
      if (tryParseFeed(body) == null) {
        final SwayveAuthState failed = const SwayveAuthState(
          status: SwayveAuthStatus.failed,
          message: 'YouTube Music did not recognise that session. Copy the '
              'cookie again from a browser signed into music.youtube.com.',
        );
        _publish(failed);
        return failed;
      }
      const SwayveAuthState signedIn = SwayveAuthState(
        status: SwayveAuthStatus.signedIn,
        // No account display name. Unlike a dedicated "who am I" endpoint, a
        // playlist browse response does not reliably carry one, and this
        // change does not guess at a JSON path with no live account response
        // to check it against — see the report on the change that added
        // this file. A host still shows "Connected" without a name.
      );
      _validatedCookie = cookie;
      _validatedState = signedIn;
      _publish(signedIn);
      return signedIn;
    } on SwayvePluginException catch (error) {
      // A network or service failure while checking is not "the flow could
      // not be started at all" — the SDK reserves throwing for that. It is
      // reported as a failed sign-in instead, the same as a rejected cookie.
      final SwayveAuthState failed = SwayveAuthState(
        status: SwayveAuthStatus.failed,
        message: 'Could not verify the YouTube Music session '
            '(${error.code}).',
      );
      _publish(failed);
      return failed;
    } on TimeoutException {
      final SwayveAuthState failed = const SwayveAuthState(
        status: SwayveAuthStatus.failed,
        message: 'YouTube Music took too long to answer. Try again.',
      );
      _publish(failed);
      return failed;
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _credentials.deleteSecret(kSessionCookieSettingId);
    } catch (_) {
      // Deleting a local secret does not depend on the network, so this is
      // not expected to throw — but the contract is unconditional ("must
      // succeed even when the network is unreachable"), and this plugin's
      // own state must move to `signedOut` regardless of what the store did.
      // A user who asked to sign out sees themselves signed out either way;
      // whatever went wrong in the store is not this method's to surface.
    } finally {
      _validatedCookie = null;
      _validatedState = null;
      _publish(SwayveAuthState.signedOut);
    }
  }
}
