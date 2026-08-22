import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../json_path.dart';
import '../soundcloud_client.dart';

/// Reads, writes, and refreshes the signed-in user's OAuth token pair —
/// shared by `SoundCloudAuthProvider` (which mints the first pair through
/// the interactive authorization-code flow) and `SoundCloudLibraryProvider`
/// (which reads it back on every `likedTracks` call, refreshing first when
/// it has to). One place for this rather than two, so the two providers can
/// never disagree about where a token lives or when it counts as stale.
///
/// Three credential-store secrets, none of them declared `plugin.json`
/// settings — unlike [kClientIdSettingId]/[kClientSecretSettingId], nothing
/// here is ever typed in by hand, so there is nothing for the settings
/// screen to render a field for. `SwayveCredentialStore` has no such
/// restriction: a plugin's secret keys are free-form, not limited to what
/// the manifest names.
final class SoundCloudOAuthTokens {
  /// Creates a store over [client] and [credentials].
  SoundCloudOAuthTokens({
    required SoundCloudClient client,
    required SwayveCredentialStore credentials,
  })  : _client = client,
        _credentials = credentials;

  final SoundCloudClient _client;
  final SwayveCredentialStore _credentials;

  static const String _accessTokenKey = 'oauth_access_token';
  static const String _refreshTokenKey = 'oauth_refresh_token';
  static const String _expiresAtKey = 'oauth_access_token_expires_at';

  /// Refreshed this many minutes before the stated expiry rather than
  /// exactly at it — the same "don't hand back something that expires
  /// before it can be used" margin `kStreamExpiryMargin` applies to a
  /// resolved stream URL, for the same reason.
  static const Duration _expiryMargin = Duration(minutes: 2);

  /// Whether a session is stored at all — cheap, no network, safe for
  /// `SoundCloudAuthProvider.authState` to call on every check.
  Future<bool> hasStoredSession() async =>
      await _credentials.readSecret(_accessTokenKey) != null;

  /// Records [tokenResponse] — the decoded body of either token-endpoint
  /// call — as the current session.
  ///
  /// `refresh_token` is optional here on purpose: SoundCloud's own refresh
  /// response is not guaranteed to include a new one (refresh token
  /// rotation is a per-provider choice, not something this plugin can
  /// assume either way), and a response that omits it means the existing
  /// stored one is still the one to use next time — overwriting it with
  /// nothing would end the session on its *next* refresh instead of this
  /// one. Same reasoning for `expires_in`: its absence means "no stated
  /// expiry," not "already expired," so the stored expiry is cleared rather
  /// than backdated.
  Future<void> store(Map<String, Object?> tokenResponse) async {
    final String? accessToken = stringAt(
      tokenResponse,
      const <Object>['access_token'],
    );
    if (accessToken == null) {
      malformedResponse('a token response had no access_token.');
    }
    await _credentials.writeSecret(_accessTokenKey, accessToken);

    final String? refreshToken = stringAt(
      tokenResponse,
      const <Object>['refresh_token'],
    );
    if (refreshToken != null) {
      await _credentials.writeSecret(_refreshTokenKey, refreshToken);
    }

    final int? expiresIn = intAt(tokenResponse, const <Object>['expires_in']);
    if (expiresIn != null) {
      final DateTime expiresAt = DateTime.now().toUtc().add(
            Duration(seconds: expiresIn),
          );
      await _credentials.writeSecret(
        _expiresAtKey,
        expiresAt.toIso8601String(),
      );
    } else {
      await _credentials.deleteSecret(_expiresAtKey);
    }
  }

  /// Discards the whole session — every secret this class ever wrote.
  Future<void> clear() async {
    await _credentials.deleteSecret(_accessTokenKey);
    await _credentials.deleteSecret(_refreshTokenKey);
    await _credentials.deleteSecret(_expiresAtKey);
  }

  /// A currently-usable `access_token`, refreshing first if the stored one
  /// is expired or about to be — proactive, not a guarantee: a token this
  /// returns as "still good" can still be rejected by the API itself (a
  /// revoked session, a clock far enough off that the stored expiry lied),
  /// which is what [forceRefresh] is for.
  ///
  /// Throws `SwayvePluginAuthRequiredException` when there is no stored
  /// session at all, or when refreshing an expired one fails.
  Future<String> validAccessToken({
    required String clientId,
    required String clientSecret,
    SwayveCancellationToken? cancel,
  }) async {
    final String? accessToken = await _credentials.readSecret(
      _accessTokenKey,
    );
    if (accessToken == null) {
      throw const SwayvePluginAuthRequiredException(
        'SoundCloud: sign in to see your liked tracks.',
      );
    }
    if (!await _isExpiredOrExpiringSoon()) return accessToken;
    return forceRefresh(
      clientId: clientId,
      clientSecret: clientSecret,
      cancel: cancel,
    );
  }

  Future<bool> _isExpiredOrExpiringSoon() async {
    final String? raw = await _credentials.readSecret(_expiresAtKey);
    // No stated expiry is treated as "still good" — see [store]'s doc
    // comment. A token that has in fact gone bad is caught reactively by
    // [forceRefresh] the moment the API actually rejects it.
    if (raw == null) return false;
    final DateTime? expiresAt = DateTime.tryParse(raw);
    if (expiresAt == null) return false;
    return DateTime.now().toUtc().isAfter(expiresAt.subtract(_expiryMargin));
  }

  /// Refreshes unconditionally, regardless of what the stored expiry says —
  /// the reactive half of this class's contract, for a caller whose actual
  /// API call was rejected despite [validAccessToken] having called the
  /// stored token good.
  ///
  /// Throws `SwayvePluginAuthRequiredException`, and clears the whole
  /// stored session first, when there is no refresh token to use or
  /// SoundCloud rejects it (revoked, or genuinely expired) — the caller's
  /// cue that nothing short of a fresh interactive sign-in will do.
  Future<String> forceRefresh({
    required String clientId,
    required String clientSecret,
    SwayveCancellationToken? cancel,
  }) async {
    final String? refreshToken = await _credentials.readSecret(
      _refreshTokenKey,
    );
    if (refreshToken == null) {
      await clear();
      throw const SwayvePluginAuthRequiredException(
        'SoundCloud: sign in again to refresh your session.',
      );
    }
    try {
      final Map<String, Object?> response = await _client.refreshAccessToken(
        clientId: clientId,
        clientSecret: clientSecret,
        refreshToken: refreshToken,
        cancel: cancel,
      );
      await store(response);
      final String? accessToken = stringAt(
        response,
        const <Object>['access_token'],
      );
      if (accessToken == null) {
        await clear();
        throw const SwayvePluginAuthRequiredException(
          'SoundCloud: sign in again to refresh your session.',
        );
      }
      return accessToken;
    } on SwayvePluginAuthRequiredException {
      await clear();
      rethrow;
    }
  }
}
