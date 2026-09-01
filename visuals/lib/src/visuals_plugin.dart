import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'spotify_app_auth.dart';
import 'spotify_auth.dart';
import 'spotify_client.dart';
import 'tidal_auth.dart';
import 'tidal_client.dart';
import 'visuals_provider.dart';

/// The source-agnostic moving visuals plugin.
final class VisualsPlugin implements SwayvePlugin {
  /// Creates the plugin with manifest-matching timeouts.
  VisualsPlugin({this.timeouts = VisualsTimeouts.manifest});

  /// The provider deadlines.
  final VisualsTimeouts timeouts;

  TidalClient? _client;
  TidalTokenSource? _tokens;
  SpotifyCanvasClient? _spotify;
  SpotifyTokenSource? _spotifyTokens;
  SpotifyAppTokenSource? _spotifyAppTokens;
  SourceAgnosticVisualsProvider? _visuals;

  /// The registered visuals provider, or `null` before initialization.
  SourceAgnosticVisualsProvider? get visualsProvider => _visuals;

  /// The TIDAL client, or `null` before initialization.
  TidalClient? get client => _client;

  /// The bearer-token source backing the official catalog, or `null` before
  /// initialization.
  TidalTokenSource? get tokens => _tokens;

  /// The Spotify canvas client, or `null` before initialization.
  SpotifyCanvasClient? get spotifyClient => _spotify;

  /// The Spotify web-player token source, or `null` before initialization.
  SpotifyTokenSource? get spotifyTokens => _spotifyTokens;

  /// The Spotify application token source, or `null` before initialization.
  SpotifyAppTokenSource? get spotifyAppTokens => _spotifyAppTokens;

  @override
  SwayvePluginIdentity get identity => const SwayvePluginIdentity(
        id: kVisualsPluginId,
        name: kVisualsPluginName,
        version: kVisualsPluginVersion,
        swayvePluginApi: kSwayvePluginApiVersion,
        capabilities: <SwayveCapability>{SwayveCapability.visuals},
        permissions: <SwayvePermission>{
          SwayvePermission.network,
          // The client id and secret are `secret` settings and therefore
          // require the external-auth permission under the manifest rules,
          // even though the plugin also works with neither of them set.
          SwayvePermission.externalAuth,
        },
      );

  @override
  Future<void> initialize(SwayvePluginContext context) async {
    final TidalClient client = TidalClient(
      http: context.http,
      region: _region(context.host.region),
      timeouts: timeouts,
    );
    _client = client;
    final TidalTokenSource tokens = TidalTokenSource(
      http: context.http,
      clientId: () => context.settings.value<String>(kTidalClientIdSettingId),
      clientSecret: () =>
          context.settings.value<String>(kTidalClientSecretSettingId),
      timeouts: timeouts,
    );
    _tokens = tokens;

    final SpotifyTokenSource spotifyTokens = SpotifyTokenSource(
      http: context.http,
      spDc: () => context.settings.value<String>(kSpotifySpDcSettingId),
      totpVersion: () =>
          context.settings.value<String>(kSpotifyTotpVersionSettingId),
      timeouts: timeouts,
    );
    _spotifyTokens = spotifyTokens;
    final SpotifyAppTokenSource spotifyAppTokens = SpotifyAppTokenSource(
      http: context.http,
      clientId: () => context.settings.value<String>(kSpotifyClientIdSettingId),
      clientSecret: () =>
          context.settings.value<String>(kSpotifyClientSecretSettingId),
      timeouts: timeouts,
    );
    _spotifyAppTokens = spotifyAppTokens;
    final SpotifyCanvasClient spotify = SpotifyCanvasClient(
      http: context.http,
      tokens: spotifyTokens,
      appTokens: spotifyAppTokens,
      timeouts: timeouts,
    );
    _spotify = spotify;

    // Order is the whole of the fallback policy, and every source in it
    // stands aside silently when it has not been configured.
    //
    // Spotify's canvas goes first because it is the most specific thing any
    // of these can return: authored for one recording rather than attached to
    // a release. TIDAL's official API answers next when it has been given
    // credentials to answer with; the credential-free TIDAL catalog answers
    // when neither of the two above did, which for most people is always.
    _visuals = SourceAgnosticVisualsProvider(
      <VisualsSource>[
        SpotifyCanvasVisualsSource(
          client: spotify,
          tokens: spotifyTokens,
          appTokens: spotifyAppTokens,
          log: context.log,
        ),
        TidalOfficialVisualsSource(client: client, tokens: tokens),
        TidalLegacyVisualsSource(client: client),
      ],
      timeouts: timeouts,
    );
    context.registerVisualsProvider(_visuals!);
    final List<String> active = <String>[
      if (spotifyTokens.isConfigured && spotifyAppTokens.isConfigured)
        'Spotify canvases',
      if (tokens.isConfigured) 'official TIDAL catalog',
      'credential-free TIDAL catalog',
    ];
    context.log.info(
      'Moving visuals ready, in order: ${active.join(', ')}.',
    );
    // Said separately, because a half-configured source is the one state
    // somebody is actively in the middle of and most needs told about.
    if (spotifyTokens.isConfigured && !spotifyAppTokens.isConfigured) {
      context.log.warn(
        'Spotify canvases are off: the sp_dc cookie is set, but the Spotify '
        'application client id and secret are not. Both are needed — the '
        'cookie fetches the canvas, the application credential finds the '
        'recording.',
      );
    } else if (!spotifyTokens.isConfigured && spotifyAppTokens.isConfigured) {
      context.log.warn(
        'Spotify canvases are off: the application credential is set, but '
        'the sp_dc cookie is not.',
      );
    }
  }

  @override
  Future<void> dispose() async {
    _client = null;
    _tokens = null;
    _spotify = null;
    _spotifyTokens = null;
    _spotifyAppTokens = null;
    _visuals = null;
  }
}

String _region(String? value) {
  final String candidate = value?.trim().toUpperCase() ?? '';
  return RegExp(r'^[A-Z]{2}$').hasMatch(candidate) ? candidate : 'US';
}
