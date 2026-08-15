import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../artwork.dart';
import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../innertube_client.dart';
import '../parsing/detail_parser.dart';

/// YouTube Music's answer to `SwayveArtworkProvider`. Capability: `artwork`.
///
/// A track costs **no request at all**: YouTube publishes a fixed ladder of
/// thumbnail variants under `i.ytimg.com/vi/<videoId>/`, so a size maps onto a
/// URL arithmetically. That matters more than it looks — artwork is asked for
/// once per visible row, and a provider that fetched to answer would turn one
/// scroll into fifty requests against a rate-limited service.
///
/// Albums, artists and playlists have no such derivation, so those do browse.
/// What comes back is filtered: an image URL on a host the manifest does not
/// declare is dropped, because `SwayveImageRef` is a location the *host*
/// fetches through the same restricted client, and handing over a URL the
/// plugin is not permitted to name is an attempt to widen its own reach.
/// See the README section "Artwork the plugin will not show you".
final class YouTubeMusicArtworkProvider implements SwayveArtworkProvider {
  /// Creates a provider over [client].
  YouTubeMusicArtworkProvider({
    required InnerTubeClient client,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  }) : _client = client;

  final InnerTubeClient _client;

  /// The deadlines this provider works to.
  final YouTubeMusicTimeouts timeouts;

  @override
  Future<SwayveImageRef?> artwork(
    SwayveMediaId id, {
    SwayveArtworkSize size = SwayveArtworkSize.medium,
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'artwork',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final YouTubeMusicIdKind? kind = YouTubeMusicIds.kindOf(id);
          if (kind == null) return null;
          if (kind == YouTubeMusicIdKind.track) {
            return YouTubeMusicArtwork.forVideo(id.value, size: size);
          }
          final String browseId = kind == YouTubeMusicIdKind.playlist
              ? YouTubeMusicIds.playlistBrowseId(id.value)
              : id.value;
          final Map<String, Object?> body = await _client.browse(
            browseId,
            cancel: cancel,
          );
          cancel?.throwIfCancelled();
          return parseHeaderArtwork(body, size: size);
        },
      );
}
