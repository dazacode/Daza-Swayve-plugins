import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
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
  SourceAgnosticVisualsProvider? _visuals;

  /// The registered visuals provider, or `null` before initialization.
  SourceAgnosticVisualsProvider? get visualsProvider => _visuals;

  /// The TIDAL client, or `null` before initialization.
  TidalClient? get client => _client;

  /// The bearer-token source backing the official catalog, or `null` before
  /// initialization.
  TidalTokenSource? get tokens => _tokens;

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

    // Order is the whole of the fallback policy. The official API answers
    // first when it has been given credentials to answer with; the
    // credential-free catalog answers when it has not, or when the official
    // catalog knows the release but names no animated cover for it.
    _visuals = SourceAgnosticVisualsProvider(
      <VisualsSource>[
        TidalOfficialVisualsSource(client: client, tokens: tokens),
        TidalLegacyVisualsSource(client: client),
      ],
      timeouts: timeouts,
    );
    context.registerVisualsProvider(_visuals!);
    context.log.info(
      tokens.isConfigured
          ? 'Moving visuals ready: official TIDAL catalog, with the '
              'credential-free catalog behind it.'
          : 'Moving visuals ready: credential-free TIDAL catalog. Add TIDAL '
              'application credentials to try the official API first.',
    );
  }

  @override
  Future<void> dispose() async {
    _client = null;
    _tokens = null;
    _visuals = null;
  }
}

String _region(String? value) {
  final String candidate = value?.trim().toUpperCase() ?? '';
  return RegExp(r'^[A-Z]{2}$').hasMatch(candidate) ? candidate : 'US';
}
