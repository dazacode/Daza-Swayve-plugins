/// The YouTube Music plugin for Swayve.
///
/// This is the library named by `plugin.json`'s `entrypoint`. A host obtains
/// an instance through [createYouTubeMusicPlugin] — the registration symbol —
/// and then speaks only to the SDK's provider interfaces. Nothing exported
/// here requires the host to know that YouTube exists: it hands over
/// `SwayveTrack`s, `SwayveAlbum`s and a generic `SwayvePlayableSource`, and
/// the host renders them the same way it renders anything else.
///
/// ```dart
/// final SwayvePlugin plugin = createYouTubeMusicPlugin();
/// await plugin.initialize(context);   // registers ten providers
/// ```
///
/// The plugin is **pure Dart**. It depends on `swayve_plugin_sdk` and nothing
/// else — no Flutter, no HTTP client, no media library — because every
/// capability it needs is mediated by `SwayvePluginContext`. See `README.md`
/// for why the obvious YouTube libraries are deliberately absent, and why
/// playback resolves to an embedded player rather than an extracted stream.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'src/youtube_music_plugin.dart';

export 'src/artwork.dart' show YouTubeMusicArtwork;
export 'src/auth/sapisid_hash.dart' show sapisidHashAuthorization, sha1Bytes;
export 'src/config.dart'
    show
        YouTubeMusicClientIdentity,
        YouTubeMusicTimeouts,
        isAllowedHost,
        kDefaultIncludeVideos,
        kDefaultRegion,
        kIncludeVideosSettingId,
        kPageIdHeader,
        kPageIdSettingId,
        kCaptionsClients,
        kPlayerClientName,
        kRegionSettingId,
        kSessionCookieSettingId,
        kStreamChunkBytes,
        kStreamExpiryMargin,
        kStreamLifetime,
        kYouTubeMusicAllowedHosts,
        kYouTubeMusicMetadataSearchHosts,
        kYouTubeMusicPluginId,
        kYouTubeMusicPluginName,
        kYouTubeMusicPluginVersion,
        kYouTubeMusicSource;
export 'src/config.dart' show YouTubeMusicFeeds, YouTubeMusicRadio;
export 'src/embed_document.dart' show youTubeEmbedDocument;
export 'src/ids.dart' show YouTubeMusicIdKind, YouTubeMusicIds;
export 'src/providers/artwork_provider.dart';
export 'src/providers/auth_provider.dart';
export 'src/providers/catalog_provider.dart';
export 'src/parsing/caption_parser.dart' show parseCaptionLines;
export 'src/parsing/mood_parser.dart' show MoodChip, parseMoodChips;
export 'src/parsing/watch_parser.dart'
    show
        ParsedWatchQueue,
        WatchSeed,
        isAudioOnlyType,
        parseWatchQueue,
        relatedBrowseIdOf,
        trackKindForMusicVideoType;
export 'src/providers/library_provider.dart';
export 'src/providers/lyrics_provider.dart';
export 'src/providers/metadata_search_provider.dart';
export 'src/providers/playlist_provider.dart';
export 'src/providers/radio_provider.dart';
export 'src/providers/search_provider.dart';
export 'src/providers/stream_provider.dart';
export 'src/youtube_music_plugin.dart' show YouTubeMusicPlugin;

/// Creates the YouTube Music plugin.
///
/// This is the single symbol a compiled plugin exposes, matching the
/// `SwayvePluginFactory` typedef. It is cheap, synchronous and free of side
/// effects: all real work belongs in `SwayvePlugin.initialize`.
///
/// The manifest's `entrypoint` is `youtube_music`, which names this library
/// and the directory it lives in. It is not this function's name because
/// Dart's own lints require identifiers to be lowerCamelCase, and a
/// `youtube_music()` function would fail the repository's analysis baseline.
SwayvePlugin createYouTubeMusicPlugin() => YouTubeMusicPlugin();
