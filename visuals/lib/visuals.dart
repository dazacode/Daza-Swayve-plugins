/// The Swayve source-agnostic moving visuals plugin.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'src/visuals_plugin.dart';

export 'src/config.dart'
    show
        VisualsTimeouts,
        isAllowedHost,
        kDurationTolerance,
        kTidalAccessTokenSettingId,
        kTidalApiOrigin,
        kUserAgent,
        kVisualsAllowedHosts,
        kVisualsPluginId,
        kVisualsPluginName,
        kVisualsPluginVersion;
export 'src/tidal_client.dart' show TidalClient, TidalVideo;
export 'src/visuals_plugin.dart' show VisualsPlugin;
export 'src/visuals_provider.dart'
    show SourceAgnosticVisualsProvider, TidalVisualsSource, VisualsSource;

/// Creates the compiled plugin instance.
SwayvePlugin createVisualsPlugin() => VisualsPlugin();
