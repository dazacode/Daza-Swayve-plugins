import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../json_path.dart';
import '../parsing/track_parser.dart';
import '../soundcloud_client.dart';

/// SoundCloud's answer to `SwayveLibraryProvider`. Capability:
/// `personal_library`.
///
/// The signed-in user's own liked tracks. Unlike an artist's *public*
/// activity — see `providers/artist_activity_provider.dart`, which reads the
/// same `/users/{id}/likes` shape for any known user id, unauthenticated —
/// this provider has no target id handed to it at all: the plugin's own
/// stored session cookie *is* the account whose shelf this reads, and
/// resolving *which* account that is takes an extra round trip
/// [SoundCloudClient.me] makes on the caller's behalf, because a cookie alone
/// does not carry a numeric user id this plugin's ids are built from.
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
        _credentials = credentials;

  final SoundCloudClient _client;
  final SwayveCredentialStore _credentials;

  /// The deadlines this provider works to.
  final SoundCloudTimeouts timeouts;

  /// The numeric user id [_resolveMyUserId] last resolved, and the cookie it
  /// was resolved for.
  ///
  /// Cached so that paging through a large liked-tracks shelf costs one `/me`
  /// lookup rather than one per page — the cursor `userLikes` follows past
  /// page one is already scoped to this account and does not need the id
  /// repeated. Invalidated the moment the stored cookie itself changes, which
  /// is the one case a cached id could be wrong: someone re-ran sign-in with
  /// a different account while this plugin instance kept running.
  int? _myUserId;
  String? _myUserIdForCookie;

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
              'SoundCloud: sign in to see your liked tracks.',
            );
          }

          final int userId = await _resolveMyUserId(cookie, cancel: cancel);
          final SoundCloudPage page = await _client.userLikes(
            userId,
            cursor: request.cursor,
            sessionCookie: cookie,
            cancel: cancel,
          );
          final List<Object?> unwrapped = <Object?>[
            for (final Object? item in page.items) unwrapChartItem(item),
          ];
          return SwayvePage<SwayveTrack>(
            items: parseTrackList(unwrapped),
            cursor: page.nextHref,
          );
        },
      );

  /// The signed-in user's own numeric id, resolved through
  /// [SoundCloudClient.me] and cached — see [_myUserId].
  ///
  /// Throws `SwayvePluginAuthRequiredException` for a cookie SoundCloud does
  /// not recognise, the same signal `SoundCloudAuthProvider.authenticate`
  /// treats as a stale session — a call here happens only once `authState`
  /// has already reported this session as signed in, so a rejection at this
  /// point means the session has gone bad since, not that nobody ever signed
  /// in.
  Future<int> _resolveMyUserId(
    String cookie, {
    SwayveCancellationToken? cancel,
  }) async {
    final int? cached = _myUserId;
    if (cached != null && _myUserIdForCookie == cookie) {
      return cached;
    }
    final Map<String, Object?>? me =
        await _client.me(sessionCookie: cookie, cancel: cancel);
    final int? id = me == null ? null : intAt(me, const <Object>['id']);
    if (id == null) {
      throw const SwayvePluginAuthRequiredException(
        'SoundCloud: sign in to see your liked tracks.',
      );
    }
    _myUserId = id;
    _myUserIdForCookie = cookie;
    return id;
  }
}
