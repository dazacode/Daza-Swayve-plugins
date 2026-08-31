/// The Swayve source-agnostic moving visuals plugin.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'src/visuals_plugin.dart';

export 'src/config.dart'
    show
        VisualsTimeouts,
        isAllowedHost,
        kDurationTolerance,
        kAnimatedCoverEdge,
        kTidalApiOrigin,
        kTidalClientIdSettingId,
        kTidalClientSecretSettingId,
        kTidalLegacyApiOrigin,
        kTidalLegacyClientToken,
        kTidalResourcesOrigin,
        kTidalTokenEndpoint,
        kUserAgent,
        kVisualsAllowedHosts,
        kVisualsPluginId,
        kVisualsPluginName,
        kVisualsPluginVersion;
export 'src/tidal_auth.dart' show TidalTokenSource;
export 'src/tidal_client.dart' show TidalClient, animatedCoverUri;
export 'src/visuals_plugin.dart' show VisualsPlugin;
export 'src/visuals_provider.dart'
    show
        SourceAgnosticVisualsProvider,
        TidalLegacyVisualsSource,
        TidalOfficialVisualsSource,
        VisualsSource;

/// Creates the compiled plugin instance.
SwayvePlugin createVisualsPlugin() => VisualsPlugin();
