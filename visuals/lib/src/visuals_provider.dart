import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'spotify_app_auth.dart';
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
    required SpotifyAppTokenSource appTokens,
  })  : _client = client,
        _tokens = tokens,
        _appTokens = appTokens;

  final SpotifyCanvasClient _client;
  final SpotifyTokenSource _tokens;
  final SpotifyAppTokenSource _appTokens;

  @override
  Future<SwayveVisual?> visual(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  }) async {
    // Not configured is the one case that answers null. It is a statement
    // about this install, not about this recording, and it is the state
    // almost every install is in.
    if (!_tokens.isConfigured) return null;

    // The cookie alone is not enough, and saying so beats going quiet. Half a
    // configuration is somebody who tried: they pasted the cookie, the field
    // for it exists, and nothing on screen would otherwise explain why the
    // background never moves. Thrown rather than returned so the host records
    // it and declines to cache a negative — see the rethrow below.
    if (!_appTokens.isConfigured) {
      throw const SwayvePluginAuthRequiredException(
        'Spotify canvases need a Spotify application client id and secret '
        'as well as the sp_dc cookie. The cookie fetches the canvas; the '
        'application credential finds the recording.',
      );
    }

    try {
      return await _client.canvas(track, cancel: cancel);
    } on SwayvePluginAuthRequiredException {
      // The cookie has expired, or the embedded TOTP version has been
      // rotated. Drop the cached token so a corrected setting takes effect
      // without an app restart.
      _tokens.invalidate();

      // Then rethrow, rather than answering null as an earlier version of
      // this did. Returning null here looked kinder — the provider falls
      // through to TIDAL either way, because `SourceAgnosticVisualsProvider`
      // only surfaces a failure when no source produced anything — but it
      // was wrong twice over.
      //
      // A host distinguishes "this recording has no canvas" from "this
      // source could not answer", and it must: the first is worth
      // remembering and the second is not. Swayve's own catalogue caches a
      // negative answer for ten minutes and deliberately declines to cache
      // one when a provider threw, precisely so that configuring a plugin
      // takes effect without restarting the app. Swallowing this exception
      // handed it a confident "no canvas for this song" the moment a cookie
      // was wrong, poisoned that cache for ten minutes, and re-created the
      // restart-to-apply behaviour the host had gone out of its way to
      // remove.
      //
      // It also made the failure invisible. A rejected cookie is the single
      // most likely thing to go wrong here, and it produced no error, no
      // warning and no log line anywhere — the symptom was a background that
      // silently stayed still.
      rethrow;
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
