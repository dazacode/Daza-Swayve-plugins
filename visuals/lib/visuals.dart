/// The Swayve source-agnostic moving visuals plugin.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'src/visuals_plugin.dart';

export 'src/canvas_protobuf.dart'
    show CanvasEntry, decodeCanvasResponse, encodeCanvasRequest;
export 'src/config.dart'
    show
        VisualsTimeouts,
        isAllowedHost,
        kAnimatedCoverEdge,
        kSpotifyCanvasEndpoint,
        kSpotifySearchEndpoint,
        kSpotifySearchLimit,
        kSpotifyServerTimeEndpoint,
        kSpotifySpDcSettingId,
        kSpotifyTokenEndpoint,
        kSpotifyTotpVersionSettingId,
        kSpotifyWebOrigin,
        kSpotifyWebUserAgent,
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
export 'src/hmac_sha1.dart' show hmacSha1, sha1;
export 'src/matching.dart'
    show
        artistsAgree,
        durationsAgree,
        kMatchDurationTolerance,
        normalizeForMatch,
        titlesAgree,
        tokenOverlap;
export 'src/spotify_auth.dart' show SpotifyTokenSource;
export 'src/spotify_client.dart' show SpotifyCanvasClient;
export 'src/spotify_totp.dart'
    show
        kSpotifyTotpCipher,
        kSpotifyTotpVersion,
        kTotpDigits,
        kTotpPeriod,
        spotifyTotpAt,
        spotifyTotpSecret,
        totpCode,
        totpCounterAt;
export 'src/tidal_auth.dart' show TidalTokenSource;
export 'src/tidal_client.dart' show TidalClient, animatedCoverUri;
export 'src/visuals_plugin.dart' show VisualsPlugin;
export 'src/visuals_provider.dart'
    show
        SourceAgnosticVisualsProvider,
        SpotifyCanvasVisualsSource,
        TidalLegacyVisualsSource,
        TidalOfficialVisualsSource,
        VisualsSource;

/// Creates the compiled plugin instance.
SwayvePlugin createVisualsPlugin() => VisualsPlugin();
