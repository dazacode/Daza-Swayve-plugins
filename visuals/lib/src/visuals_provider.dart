import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
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

/// The SDK provider that tries registered source adapters in order.
///
/// TIDAL is the only source currently registered. The list and interface are
/// deliberately source-agnostic so a future Apple Music adapter can be added
/// when it has a safe, host-compatible authorization path.
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
