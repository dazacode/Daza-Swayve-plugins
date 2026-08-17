/// The SoundCloud plugin for Swayve.
///
/// This is the library named by `plugin.json`'s `entrypoint`. A host obtains
/// an instance through [createSoundCloudPlugin] — the registration symbol —
/// and then speaks only to the SDK's provider interfaces. Nothing exported
/// here requires the host to know that SoundCloud exists: it hands over
/// `SwayveTrack`s, `SwayveAlbum`s, `SwayvePlaylist`s and a generic
/// `SwayvePlayableSource`, and the host renders them the same way it renders
/// anything else.
///
/// ```dart
/// final SwayvePlugin plugin = createSoundCloudPlugin();
/// await plugin.initialize(context);   // registers five providers
/// ```
///
/// The plugin is **pure Dart**. It depends on `swayve_plugin_sdk` and nothing
/// else — no Flutter, no HTTP client — because every capability it needs is
/// mediated by `SwayvePluginContext`. See `README.md` for why it talks to
/// SoundCloud's public, unauthenticated API rather than the official OAuth
/// one.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'src/soundcloud_plugin.dart';

export 'src/config.dart'
    show
        SoundCloudChartKind,
        SoundCloudTimeouts,
        chartKindFor,
        isAllowedHost,
        kDefaultRegion,
        kRegionSettingId,
        kSoundCloudAllowedHosts,
        kSoundCloudPluginId,
        kSoundCloudPluginName,
        kSoundCloudPluginVersion,
        kStreamExpiryMargin,
        kStreamLifetime;
export 'src/ids.dart' show SoundCloudIdKind, SoundCloudIds;
export 'src/parsing/artwork.dart' show SoundCloudArtwork;
export 'src/providers/artwork_provider.dart';
export 'src/providers/catalog_provider.dart';
export 'src/providers/playlist_provider.dart';
export 'src/providers/search_provider.dart';
export 'src/providers/stream_provider.dart';
export 'src/soundcloud_client.dart'
    show SoundCloudClient, SoundCloudClientIdException, SoundCloudPage;
export 'src/soundcloud_plugin.dart' show SoundCloudPlugin;

/// Creates the SoundCloud plugin.
///
/// This is the single symbol a compiled plugin exposes, matching the
/// `SwayvePluginFactory` typedef. It is cheap, synchronous and free of side
/// effects: all real work belongs in `SwayvePlugin.initialize`.
///
/// The manifest's `entrypoint` is `soundcloud`, which names this library and
/// the directory it lives in — not this function's name, since Dart's own
/// lints require lowerCamelCase identifiers and a `soundcloud()` function
/// would fail this repository's analysis baseline.
SwayvePlugin createSoundCloudPlugin() => SoundCloudPlugin();
