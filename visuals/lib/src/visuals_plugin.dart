import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'tidal_client.dart';
import 'visuals_provider.dart';

/// The source-agnostic moving visuals plugin.
final class VisualsPlugin implements SwayvePlugin {
  /// Creates the plugin with manifest-matching timeouts.
  VisualsPlugin({this.timeouts = VisualsTimeouts.manifest});

  /// The provider deadlines.
  final VisualsTimeouts timeouts;

  TidalClient? _client;
  SourceAgnosticVisualsProvider? _visuals;

  /// The registered visuals provider, or `null` before initialization.
  SourceAgnosticVisualsProvider? get visualsProvider => _visuals;

  /// The TIDAL client, or `null` before initialization.
  TidalClient? get client => _client;

  @override
  SwayvePluginIdentity get identity => const SwayvePluginIdentity(
        id: kVisualsPluginId,
        name: kVisualsPluginName,
        version: kVisualsPluginVersion,
        swayvePluginApi: kSwayvePluginApiVersion,
        capabilities: <SwayveCapability>{SwayveCapability.visuals},
        permissions: <SwayvePermission>{
          SwayvePermission.network,
          // The token is a `secret` setting and therefore requires the
          // external-auth permission under the manifest rules.
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
    _visuals = SourceAgnosticVisualsProvider(
      <VisualsSource>[
        TidalVisualsSource(
          client: client,
          accessToken: () =>
              context.settings.value<String>(kTidalAccessTokenSettingId),
        ),
      ],
      timeouts: timeouts,
    );
    context.registerVisualsProvider(_visuals!);
    context.log.info(
      'Moving visuals ready: official TIDAL video manifests only; '
      'Apple Music is not enabled.',
    );
  }

  @override
  Future<void> dispose() async {
    _client = null;
    _visuals = null;
  }
}

String _region(String? value) {
  final String candidate = value?.trim().toUpperCase() ?? '';
  return RegExp(r'^[A-Z]{2}$').hasMatch(candidate) ? candidate : 'US';
}
