import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../innertube_client.dart';
import '../parsing/feed_parser.dart';

/// YouTube Music's answer to `SwayveLibraryProvider`. Capability:
/// `personal_library`.
///
/// The signed-in user's own liked songs, read the same way any other
/// playlist browse in this plugin is read — see `providers/catalog_provider.
/// dart` for the shared shelf-parsing machinery this reuses rather than
/// duplicating. The one difference from an ordinary browse is that this one
/// carries the stored session cookie, because InnerTube answers a user's own
/// liked-music playlist only for a signed-in session; a signed-out call
/// throws `SwayvePluginAuthRequiredException` rather than an empty page, so
/// the host can tell "nothing liked yet" apart from "not signed in" — exactly
/// what [SwayveLibraryProvider.likedTracks] asks of an implementer.
final class YouTubeMusicLibraryProvider implements SwayveLibraryProvider {
  /// Creates a provider over [client] and [credentials].
  YouTubeMusicLibraryProvider({
    required InnerTubeClient client,
    required SwayveCredentialStore credentials,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  })  : _client = client,
        _credentials = credentials;

  final InnerTubeClient _client;
  final SwayveCredentialStore _credentials;

  /// The deadlines this provider works to.
  final YouTubeMusicTimeouts timeouts;

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
          final String? cookie = await _credentials.readSecret(
            kSessionCookieSettingId,
          );
          if (cookie == null || cookie.trim().isEmpty) {
            throw const SwayvePluginAuthRequiredException(
              'YouTube Music: sign in to see your liked songs.',
            );
          }

          final Map<String, Object?> body = await _client.browse(
            YouTubeMusicFeeds.likedSongs,
            continuation: request.cursor,
            sessionCookie: cookie,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();
          final ParsedFeed feed = parseFeed(body, what: 'likedTracks');
          return SwayvePage<SwayveTrack>(
            items: List<SwayveTrack>.unmodifiable(feed.items.tracks),
            cursor: feed.cursor,
          );
        },
      );
}
