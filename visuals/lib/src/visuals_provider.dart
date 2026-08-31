import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'apple_music_client.dart';
import 'tidal_client.dart';

/// Boundary for adding another official visuals source without changing the
/// SDK-facing provider or host.
abstract interface class VisualsSource {
  /// Finds a visual for [track], or returns `null` when this source has none.
  Future<SwayveVisual?> visual(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  });
}

/// The verified TIDAL source implementation.
final class TidalVisualsSource implements VisualsSource {
  /// Creates the source.
  TidalVisualsSource({
    required TidalClient client,
    required String? Function() accessToken,
  })  : _client = client,
        _accessToken = accessToken;

  final TidalClient _client;
  final String? Function() _accessToken;

  @override
  Future<SwayveVisual?> visual(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  }) {
    final String? token = _accessToken()?.trim();
    if (token == null || token.isEmpty) {
      throw const SwayvePluginAuthRequiredException(
        'Configure an official TIDAL access token to resolve visuals.',
      );
    }
    return _client.visual(track, accessToken: token, cancel: cancel);
  }
}

/// Apple Music's official catalog preview-video source.
final class AppleMusicVisualsSource implements VisualsSource {
  AppleMusicVisualsSource({
    required AppleMusicClient client,
    required String? Function() developerToken,
    required String? Function() storefront,
  })  : _client = client,
        _developerToken = developerToken,
        _storefront = storefront;

  final AppleMusicClient _client;
  final String? Function() _developerToken;
  final String? Function() _storefront;

  @override
  Future<SwayveVisual?> visual(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  }) {
    final token = _developerToken()?.trim();
    if (token == null || token.isEmpty) {
      throw const SwayvePluginAuthRequiredException(
        'Configure an Apple Music developer token to resolve visuals.',
      );
    }
    final rawStorefront = _storefront()?.trim().toLowerCase();
    final storefront =
        rawStorefront != null && RegExp(r'^[a-z]{2}$').hasMatch(rawStorefront)
            ? rawStorefront
            : 'us';
    return _client.visual(
      track,
      developerToken: token,
      storefront: storefront,
      cancel: cancel,
    );
  }
}

/// The SDK provider that tries registered source adapters in order.
///
/// Official sources are tried in order and remain source-agnostic to the host.
final class SourceAgnosticVisualsProvider implements SwayveVisualsProvider {
  /// Creates a provider from source adapters.
  SourceAgnosticVisualsProvider(
    Iterable<VisualsSource> sources, {
    this.timeouts = VisualsTimeouts.manifest,
  }) : _sources = List<VisualsSource>.unmodifiable(sources);

  final List<VisualsSource> _sources;

  /// The provider's operation budget.
  final VisualsTimeouts timeouts;

  @override
  Future<SwayveVisual?> visual(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  }) async {
    try {
      return await _withinOperationDeadline(() async {
        SwayvePluginException? lastFailure;
        for (final VisualsSource source in _sources) {
          cancel?.throwIfCancelled();
          try {
            final SwayveVisual? result =
                await source.visual(track, cancel: cancel);
            cancel?.throwIfCancelled();
            if (result != null) return result;
          } on SwayvePluginException catch (error) {
            lastFailure = error;
          }
        }
        if (lastFailure != null) throw lastFailure;
        return null;
      });
    } on SwayvePluginException {
      rethrow;
    } catch (error) {
      throw SwayvePluginUnavailableException(
        'The visuals lookup failed before it returned a classified result.',
        cause: error,
      );
    }
  }

  Future<T> _withinOperationDeadline<T>(Future<T> Function() work) async {
    try {
      return await work().timeout(timeouts.operation);
    } on TimeoutException catch (error) {
      throw SwayvePluginTimeoutException(
        'The visuals lookup exceeded its operation budget.',
        limit: timeouts.operation,
        cause: error,
      );
    }
  }
}
