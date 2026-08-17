import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../json_path.dart';
import '../soundcloud_client.dart';

/// SoundCloud's answer to `SwayveStreamProvider`. Capability: `streaming`.
///
/// A track's `media.transcodings[]` lists every rendition SoundCloud offers
/// for it. This provider prefers a `progressive` transcoding — a single
/// direct media URL the host's own engine plays — and falls back to the
/// first `hls` transcoding when no progressive rendition exists, which
/// happens for some Go+-restricted or explicitly HLS-only uploads. Either
/// way, the chosen transcoding's own `url` is not itself playable: it has to
/// be resolved once more through `SoundCloudClient.resolveMediaUrl`, which
/// exchanges it for the final signed CDN address. No cipher, no signature
/// math to reproduce — SoundCloud's public API hands back an already-usable
/// URL at that step, simpler than YouTube's case.
///
/// `SwayveAvailability.downloadable` is read straight from the track's own
/// `downloadable` boolean — not inferred from the fact that a resolved
/// progressive URL is technically a fetchable file. Principle 6
/// (`streamable != downloadable`) is exactly for a case like this, where the
/// upstream service states the permission itself.
final class SoundCloudStreamProvider implements SwayveStreamProvider {
  /// Creates a provider over [client].
  SoundCloudStreamProvider({
    required SoundCloudClient client,
    this.timeouts = SoundCloudTimeouts.manifest,
  }) : _client = client;

  final SoundCloudClient _client;

  /// The deadlines this provider works to.
  final SoundCloudTimeouts timeouts;

  @override
  Future<SwayvePlayableSource> resolvePlayback(
    SwayveMediaId id, {
    SwayvePlaybackHints hints = SwayvePlaybackHints.defaults,
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'resolvePlayback',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          if (!SoundCloudIds.isKind(id, SoundCloudIdKind.track)) {
            throw SwayvePluginUnsupportedException(
              'SoundCloud can only play tracks, and $id is not one.',
            );
          }
          final int numeric = SoundCloudIds.numericValue(id)!;
          final Map<String, Object?>? json =
              await _client.track(numeric, cancel: cancel);
          if (json == null) {
            throw SwayvePluginUnsupportedException(
              'SoundCloud: track $numeric no longer resolves.',
            );
          }
          cancel?.throwIfCancelled();

          final _Transcoding? chosen = _choose(
            listAt(json, <Object>['media', 'transcodings']),
          );
          if (chosen == null) {
            throw SwayvePluginUnsupportedException(
              'SoundCloud offered no playable rendition for track $numeric.',
            );
          }
          final Uri? transcodingUrl = Uri.tryParse(chosen.url);
          if (transcodingUrl == null) {
            throw SwayvePluginUnsupportedException(
              'SoundCloud: track $numeric had an unusable transcoding url.',
            );
          }

          final Uri resolvedUrl =
              await _client.resolveMediaUrl(transcodingUrl, cancel: cancel);
          final SwayveAvailability availability = SwayveAvailability(
            streamable: true,
            downloadable: boolAt(json, <Object>['downloadable']),
          );
          final Duration expiresIn = kStreamLifetime - kStreamExpiryMargin;

          return chosen.isHls
              ? SwayvePlayableSource.hls(
                  resolvedUrl,
                  expiresIn: expiresIn,
                  availability: availability,
                  mimeType: chosen.mimeType,
                )
              : SwayvePlayableSource.directUrl(
                  resolvedUrl,
                  expiresIn: expiresIn,
                  availability: availability,
                  mimeType: chosen.mimeType,
                );
        },
      );

  /// The best transcoding to resolve: the first `progressive` rendition, or
  /// the first `hls` rendition when none is progressive, or `null` when the
  /// track offers nothing playable at all.
  _Transcoding? _choose(List<Object?> transcodings) {
    _Transcoding? progressive;
    _Transcoding? hls;
    for (final Object? item in transcodings) {
      final Map<String, Object?> json = mapOf(item);
      final String? url = stringAt(json, <Object>['url']);
      final String? protocol = stringAt(json, <Object>['format', 'protocol']);
      if (url == null || protocol == null) continue;
      final _Transcoding transcoding = _Transcoding(
        url: url,
        isHls: protocol == 'hls',
        mimeType: stringAt(json, <Object>['format', 'mime_type']),
      );
      if (protocol == 'progressive') {
        progressive ??= transcoding;
      } else if (protocol == 'hls') {
        hls ??= transcoding;
      }
    }
    return progressive ?? hls;
  }
}

/// One resolved-but-not-yet-fetched transcoding option.
final class _Transcoding {
  const _Transcoding({required this.url, required this.isHls, this.mimeType});

  final String url;
  final bool isHls;
  final String? mimeType;
}
