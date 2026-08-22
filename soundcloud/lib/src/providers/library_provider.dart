import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../auth/oauth_tokens.dart';
import '../config.dart';
import '../errors.dart';
import '../parsing/track_parser.dart';
import '../soundcloud_client.dart';

/// SoundCloud's answer to `SwayveLibraryProvider`. Capability:
/// `personal_library`.
///
/// The signed-in user's own liked tracks, read through the official API's
/// `/me/likes/tracks` with the OAuth `access_token`
/// `SoundCloudAuthProvider.authenticate` obtained — see that provider's doc
/// comment for why this is a real OAuth flow rather than a captured cookie
/// forwarded through the anonymous, scraped surface every other provider in
/// this plugin uses. `/me` needs no numeric user id resolved first, unlike
/// an artist's *public* likes (`SoundCloudArtistActivityProvider`, reading
/// the same shape by id for anyone else's profile, unauthenticated): the
/// access token already names whose likes these are.
///
/// A signed-out call throws `SwayvePluginAuthRequiredException` rather than
/// an empty page — exactly what [SwayveLibraryProvider.likedTracks] asks of
/// an implementer, so the host can tell "nothing liked yet" apart from "not
/// signed in".
final class SoundCloudLibraryProvider implements SwayveLibraryProvider {
  /// Creates a provider over [client] and [credentials].
  SoundCloudLibraryProvider({
    required SoundCloudClient client,
    required SwayveCredentialStore credentials,
    this.timeouts = SoundCloudTimeouts.manifest,
  })  : _client = client,
        _credentials = credentials,
        _tokens =
            SoundCloudOAuthTokens(client: client, credentials: credentials);

  final SoundCloudClient _client;
  final SwayveCredentialStore _credentials;
  final SoundCloudOAuthTokens _tokens;

  /// The deadlines this provider works to.
  final SoundCloudTimeouts timeouts;

  @override
  Future<SwayvePage<SwayveTrack>> likedTracks(
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'likedTracks',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
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
            throw const SwayvePluginAuthRequiredException(
              'SoundCloud: sign in to see your liked tracks.',
            );
          }

          final String accessToken = await _tokens.validAccessToken(
            clientId: clientId,
            clientSecret: clientSecret,
            cancel: cancel,
          );

          final SoundCloudPage page = await _fetchPage(
            accessToken: accessToken,
            clientId: clientId,
            clientSecret: clientSecret,
            cursor: request.cursor,
            cancel: cancel,
          );
          return SwayvePage<SwayveTrack>(
            items: parseTrackList(page.items),
            cursor: page.nextHref,
          );
        },
      );

  /// Fetches one page, retrying **exactly once** with a freshly refreshed
  /// token when the stored one is rejected despite
  /// [SoundCloudOAuthTokens.validAccessToken] having called it good — the
  /// same "trust the proactive check, then recover reactively exactly once"
  /// shape [SoundCloudClient]'s own `client_id` retry follows for the
  /// anonymous surface. A rejection that survives the retry means the whole
  /// session is gone, not that this one call had bad luck.
  Future<SoundCloudPage> _fetchPage({
    required String accessToken,
    required String clientId,
    required String clientSecret,
    required String? cursor,
    SwayveCancellationToken? cancel,
  }) async {
    try {
      return await _client.officialMyLikedTracks(
        accessToken: accessToken,
        cursor: cursor,
        cancel: cancel,
      );
    } on SwayvePluginAuthRequiredException {
      final String refreshed = await _tokens.forceRefresh(
        clientId: clientId,
        clientSecret: clientSecret,
        cancel: cancel,
      );
      return _client.officialMyLikedTracks(
        accessToken: refreshed,
        cursor: cursor,
        cancel: cancel,
      );
    }
  }
}
