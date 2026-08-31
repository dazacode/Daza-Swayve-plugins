import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../parsing/radio_parser.dart';
import '../soundcloud_client.dart';

/// SoundCloud's answer to `SwayveRadioProvider`. Capability: `radio`.
///
/// SoundCloud's public related-track recommender is the service-native
/// station primitive. It provides the same collection/next_href cursor
/// contract for both a finite related shelf and a station that the host keeps
/// paging. This provider is read-only and has no host-specific behavior.
final class SoundCloudRadioProvider implements SwayveRadioProvider {
  /// Creates a provider over [client].
  SoundCloudRadioProvider({
    required SoundCloudClient client,
    this.timeouts = SoundCloudTimeouts.manifest,
  }) : _client = client;

  final SoundCloudClient _client;

  /// The deadlines this provider works to.
  final SoundCloudTimeouts timeouts;

  @override
  Future<SwayveRadio?> startRadio(
    SwayveMediaId seed, {
    SwayveMediaId? context,
    SwayveCancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (!SoundCloudIds.isKind(seed, SoundCloudIdKind.track)) return null;
    final int? trackId = SoundCloudIds.numericValue(seed);
    if (trackId == null) return null;

    // Minting is request-free. The related endpoint is the first page, so
    // radioTracks can apply the normal operation deadline to network work.
    return SwayveRadio(
      id: SoundCloudIds.radio(trackId),
      seed: seed,
      extra: <String, Object?>{'seedTrackId': trackId},
    );
  }

  @override
  Future<SwayvePage<SwayveTrack>> radioTracks(
    SwayveRadio radio,
    SwayveBrowseRequest request, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'radioTracks',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          final int? seedId = _seedIdOf(radio);
          if (seedId == null) return const SwayvePage<SwayveTrack>();
          final SoundCloudPage page = await _client.relatedTracks(
            seedId,
            limit: request.limit,
            cursor: request.cursor,
            cancel: cancel,
          );
          return SwayvePage<SwayveTrack>(
            items: parseRadioTrackList(page.items, seedId: seedId),
            cursor: page.nextHref,
          );
        },
      );

  @override
  Future<List<SwayveTrack>> related(
    SwayveMediaId id, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'related',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          if (!SoundCloudIds.isKind(id, SoundCloudIdKind.track)) {
            return const <SwayveTrack>[];
          }
          final int? trackId = SoundCloudIds.numericValue(id);
          if (trackId == null) return const <SwayveTrack>[];
          final SoundCloudPage page = await _client.relatedTracks(
            trackId,
            limit: kDefaultRadioLimit,
            cancel: cancel,
          );
          return parseRadioTrackList(page.items, seedId: trackId);
        },
      );

  int? _seedIdOf(SwayveRadio radio) {
    if (!SoundCloudIds.isKind(radio.id, SoundCloudIdKind.radio)) return null;
    final Object? stored = radio.extra['seedTrackId'];
    if (stored is int && stored > 0) return stored;
    return SoundCloudIds.numericValue(radio.id);
  }
}
