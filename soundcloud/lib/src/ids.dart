import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';

/// What a SoundCloud identifier refers to.
enum SoundCloudIdKind {
  /// A single recording.
  track,

  /// A `playlists` object — a real release when `is_album` is true, a plain
  /// playlist otherwise. The id alone does not say which; see
  /// [SoundCloudIds] for why.
  playlist,

  /// A user account.
  user,
}

/// Reading and minting the provider-native identifiers this plugin puts in
/// `SwayveMediaId.value`.
///
/// SoundCloud's `track`, `playlist` and `user` ids are all plain integers
/// assigned from a shared, overlapping numbering space — a track `12345` and
/// a playlist `12345` are unrelated entities. Unlike YouTube Music, where a
/// video id and a browse id are disjoint shapes, a bare SoundCloud id cannot
/// be classified; this plugin has to mint a distinguishable one by prefixing
/// the kind, and reverse the prefix to recover it.
///
/// Deliberately **not** encoded here: whether a playlist id names a real
/// album (`is_album: true`) or a plain playlist. An id names *what entity*,
/// not *what kind of playlist it currently is* — a creator can retitle or
/// retype a playlist after minting it — so `catalog.album(id)` and
/// `SoundCloudPlaylistProvider.playlistTracks(id)` both resolve a `p`-id
/// through the same fetch and branch on the freshly-read `is_album` field
/// rather than trusting a stale prefix.
abstract final class SoundCloudIds {
  static const String _trackPrefix = 't';
  static const String _playlistPrefix = 'p';
  static const String _userPrefix = 'u';

  static final RegExp _shape = RegExp(r'^([tpu])(\d+)$');

  /// The kind [value] denotes, or `null` when it is not one of ours.
  static SoundCloudIdKind? classify(String value) {
    final RegExpMatch? match = _shape.firstMatch(value);
    if (match == null) return null;
    return switch (match.group(1)) {
      _trackPrefix => SoundCloudIdKind.track,
      _playlistPrefix => SoundCloudIdKind.playlist,
      _userPrefix => SoundCloudIdKind.user,
      _ => null,
    };
  }

  /// The kind [id] denotes, or `null` when [id] belongs to another plugin or
  /// has an unrecognised shape.
  static SoundCloudIdKind? kindOf(SwayveMediaId id) =>
      id.pluginId == kSoundCloudPluginId ? classify(id.value) : null;

  /// Whether [id] was minted by this plugin and denotes [kind].
  static bool isKind(SwayveMediaId id, SoundCloudIdKind kind) =>
      kindOf(id) == kind;

  /// The numeric SoundCloud id [id] wraps, or `null` when [id] is foreign or
  /// malformed.
  static int? numericValue(SwayveMediaId id) {
    if (id.pluginId != kSoundCloudPluginId) return null;
    final RegExpMatch? match = _shape.firstMatch(id.value);
    if (match == null) return null;
    return int.tryParse(match.group(2)!);
  }

  /// Wraps a provider-native [numericId] of [kind] as a Swayve media id owned
  /// by this plugin.
  static SwayveMediaId mediaId(SoundCloudIdKind kind, int numericId) {
    final String prefix = switch (kind) {
      SoundCloudIdKind.track => _trackPrefix,
      SoundCloudIdKind.playlist => _playlistPrefix,
      SoundCloudIdKind.user => _userPrefix,
    };
    return SwayveMediaId(kSoundCloudPluginId, '$prefix$numericId');
  }

  /// Convenience for [mediaId] with [SoundCloudIdKind.track].
  static SwayveMediaId track(int numericId) =>
      mediaId(SoundCloudIdKind.track, numericId);

  /// Convenience for [mediaId] with [SoundCloudIdKind.playlist].
  static SwayveMediaId playlist(int numericId) =>
      mediaId(SoundCloudIdKind.playlist, numericId);

  /// Convenience for [mediaId] with [SoundCloudIdKind.user].
  static SwayveMediaId user(int numericId) =>
      mediaId(SoundCloudIdKind.user, numericId);
}
