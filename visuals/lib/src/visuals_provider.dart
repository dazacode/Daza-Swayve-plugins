import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'spotify_auth.dart';
import 'spotify_client.dart';
import 'tidal_auth.dart';
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

/// The official TIDAL Developer Platform source.
///
/// Tried first when the plugin has been given application credentials. It
/// stands aside — silently, returning null rather than throwing — when it has
/// none, because this plugin resolves covers without credentials too and an
/// unconfigured optional source is not a failure anybody asked to hear about.
final class TidalOfficialVisualsSource implements VisualsSource {
  /// Creates the source.
  TidalOfficialVisualsSource({
    required TidalClient client,
    required TidalTokenSource tokens,
  })  : _client = client,
        _tokens = tokens;

  final TidalClient _client;
  final TidalTokenSource _tokens;

  @override
  Future<SwayveVisual?> visual(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  }) async {
    if (!_tokens.isConfigured) {
      // Half a credential is somebody who tried and stopped. Saying so is
      // more use than the silence a wholly unconfigured source gets.
      if (_tokens.isHalfConfigured) {
        throw const SwayvePluginAuthRequiredException(
          'The TIDAL application needs both a client id and a client secret.',
        );
      }
      return null;
    }

    final String token = await _tokens.token(cancel: cancel);
    try {
      return await _client.officialCover(
        track,
        accessToken: token,
        cancel: cancel,
      );
    } on SwayvePluginAuthRequiredException {
      // The token was accepted when it was minted and is not now. Drop it and
      // let the next lookup mint a fresh one rather than failing every
      // request until the app restarts.
      _tokens.invalidate();
      rethrow;
    }
  }
}

/// The credential-free TIDAL catalog source.
///
/// This is the one that actually carries the feature for most people: it
/// needs no account, no application and no configuration, and the animated
/// cover it finds is the same asset the official API would name. See this
/// plugin's README for the boundary being drawn around it.
final class TidalLegacyVisualsSource implements VisualsSource {
  /// Creates the source.
  TidalLegacyVisualsSource({required TidalClient client}) : _client = client;

  final TidalClient _client;

  @override
  Future<SwayveVisual?> visual(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  }) =>
      _client.legacyCover(track, cancel: cancel);
}

/// Spotify's canvas — the short portrait loop an artist attaches to a track.
///
/// Tried first when a session cookie has been provided, and only then. Unlike
/// both TIDAL sources this one cannot work uncredentialed: Spotify mints its
/// web-player token from a real logged-in session, and there is no anonymous
/// door onto the canvas endpoint. So the unconfigured case is silence — the
/// same stance [TidalOfficialVisualsSource] takes, and for the same reason.
/// An optional source nobody switched on is not a failure anybody asked to
/// hear about.
///
/// It goes first rather than last because of what a canvas *is*. A TIDAL
/// animated cover is a moving sleeve: a nice piece of motion attached to a
/// release. A canvas is authored for one recording, by its artist, to sit
/// behind that recording specifically. When both exist, the canvas is the one
/// the person was hoping for.
///
/// ## What it costs when Spotify changes its mind
///
/// This reaches undocumented endpoints behind a rotating secret, and it will
/// break — the question is when, not whether. That is survivable here in a
/// way it would not be for a streaming source: this source returning null or
/// throwing drops the lookup through to the TIDAL sources behind it, and a
/// person who never configured it sees no change at all. The failure mode of
/// a broken add-on is a plainer background, which is why this belongs in an
/// add-on and not in anything's playback path.
final class SpotifyCanvasVisualsSource implements VisualsSource {
  /// Creates the source.
  SpotifyCanvasVisualsSource({
    required SpotifyCanvasClient client,
    required SpotifyTokenSource tokens,
  })  : _client = client,
        _tokens = tokens;

  final SpotifyCanvasClient _client;
  final SpotifyTokenSource _tokens;

  @override
  Future<SwayveVisual?> visual(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  }) async {
    if (!_tokens.isConfigured) return null;
    try {
      return await _client.canvas(track, cancel: cancel);
    } on SwayvePluginAuthRequiredException {
      // The cookie was accepted once and is not now, or the embedded TOTP
      // version has been rotated. Drop the cached token so a corrected
      // setting takes effect without an app restart, then let the provider
      // fall through to TIDAL rather than failing the whole lookup: a canvas
      // nobody can fetch is a reason to show something else, not nothing.
      _tokens.invalidate();
      return null;
    }
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
