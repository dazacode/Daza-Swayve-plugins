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
///
/// It also carries the stored `page_id`, when there is one — see
/// [kPageIdSettingId]. A cookie identifies a session; it does not settle
/// which of possibly several YouTube channels under that session's account
/// this call means. Confirmed against a real multi-channel account: without
/// the right channel selected, InnerTube answers with a normal, entirely
/// parseable, entirely empty playlist — not an error, not the "sign in"
/// placeholder [looksSignedOut] catches, just zero songs. That is
/// indistinguishable, by the shape of the response alone, from an account
/// that has genuinely liked nothing — which is exactly why this provider
/// does not try to detect the missing-channel case from an empty result. It
/// can, however, tell a *configured but rejected* channel apart from a
/// signed-out session, and does — see the `page_id`-aware branch below.
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
          final String? pageId = await _credentials.readSecret(
            kPageIdSettingId,
          );
          final bool hasPageId = pageId != null && pageId.trim().isNotEmpty;

          final Map<String, Object?> body = await _client.browse(
            YouTubeMusicFeeds.likedSongs,
            continuation: request.cursor,
            sessionCookie: cookie,
            pageId: pageId,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();
          // A stored cookie InnerTube no longer honours answers 200 with a
          // normal-shaped, perfectly parseable section list — YouTube
          // Music's own "sign in to see your liked songs" placeholder —
          // which `parseFeed` alone reads as a genuinely empty playlist. See
          // `looksSignedOut`'s doc comment; `authState`'s own optimism (a
          // stored cookie reads as signed in until something proves
          // otherwise) is exactly what makes this the moment that proof
          // arrives.
          if (looksSignedOut(body)) {
            // A configured `page_id` that InnerTube rejects looks exactly
            // like this same placeholder — YouTube does not distinguish
            // "wrong channel" from "not signed in" in its response. Told
            // apart here only by which one this session actually configured,
            // so the message points at the setting actually worth checking
            // rather than sending someone to re-paste a cookie that was
            // never the problem.
            if (hasPageId) {
              throw const SwayvePluginAuthRequiredException(
                'YouTube Music: the channel ID in Settings was not '
                'recognised for this session. Check it and try again, or '
                'clear it to use your account\'s default channel.',
              );
            }
            throw const SwayvePluginAuthRequiredException(
              'YouTube Music: sign in to see your liked songs.',
            );
          }
          final ParsedFeed feed = parseFeed(body, what: 'likedTracks');
          return SwayvePage<SwayveTrack>(
            items: List<SwayveTrack>.unmodifiable(feed.items.tracks),
            cursor: feed.cursor,
          );
        },
      );
}
