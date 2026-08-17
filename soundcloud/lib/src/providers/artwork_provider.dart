import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../json_path.dart';
import '../parsing/artwork.dart';
import '../soundcloud_client.dart';

/// SoundCloud's answer to `SwayveArtworkProvider`. Capability: `artwork`.
///
/// Unlike the YouTube Music plugin's artwork provider, this one is **not**
/// zero-request: YouTube publishes a deterministic thumbnail URL derivable
/// from a bare video id, but SoundCloud's `artwork_url` and `avatar_url`
/// exist only on the entity itself, so answering "what does this id look
/// like" means fetching the entity first. `SoundCloudArtwork.resized` still
/// makes the *size* free once that fetch has happened — the request pays for
/// learning the image exists at all, not for each size of it.
///
/// In practice this path is rarely the hot one: every [SwayveTrack],
/// [SwayveAlbum] and [SwayveArtist] this plugin returns from search or
/// catalog browsing already carries its own artwork inline, sized to
/// [SwayveArtworkSize.medium]. A host asking this provider directly is asking
/// for a size it didn't already have cached, or for an id with no inline
/// artwork to begin with.
final class SoundCloudArtworkProvider implements SwayveArtworkProvider {
  /// Creates a provider over [client].
  SoundCloudArtworkProvider({
    required SoundCloudClient client,
    this.timeouts = SoundCloudTimeouts.manifest,
  }) : _client = client;

  final SoundCloudClient _client;

  /// The deadlines this provider works to.
  final SoundCloudTimeouts timeouts;

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
          final SoundCloudIdKind? kind = SoundCloudIds.kindOf(id);
          final int? numeric = SoundCloudIds.numericValue(id);
          if (kind == null || numeric == null) return null;

          switch (kind) {
            case SoundCloudIdKind.track:
              final Map<String, Object?>? json =
                  await _client.track(numeric, cancel: cancel);
              if (json == null) return null;
              return SoundCloudArtwork.build(
                    stringAt(json, <Object>['artwork_url']),
                    size,
                  ) ??
                  SoundCloudArtwork.build(
                    stringAt(json, <Object>['user', 'avatar_url']),
                    size,
                  );
            case SoundCloudIdKind.playlist:
              final Map<String, Object?>? json =
                  await _client.playlist(numeric, cancel: cancel);
              if (json == null) return null;
              return SoundCloudArtwork.build(
                    stringAt(json, <Object>['artwork_url']),
                    size,
                  ) ??
                  SoundCloudArtwork.build(
                    stringAt(json, <Object>['user', 'avatar_url']),
                    size,
                  );
            case SoundCloudIdKind.user:
              final Map<String, Object?>? json =
                  await _client.user(numeric, cancel: cancel);
              if (json == null) return null;
              return SoundCloudArtwork.build(
                stringAt(json, <Object>['avatar_url']),
                size,
              );
          }
        },
      );
}
