/// The Lyrics plugin for Swayve.
///
/// This is the library named by `plugin.json`'s `entrypoint`. A host obtains an
/// instance through [createLyricsPlugin] — the registration symbol — and then
/// speaks only to the SDK's `SwayveLyricsProvider` interface.
///
/// ```dart
/// final SwayvePlugin plugin = createLyricsPlugin();
/// await plugin.initialize(context);   // registers one provider
/// final SwayveLyrics? words = await provider.lyrics(nowPlaying);
/// ```
///
/// What makes this plugin different from the others in this repository is that
/// it has no catalogue of its own. It never publishes a track and never mints a
/// media id; it takes a [SwayveTrack] that some *other* plugin published — from
/// YouTube Music, from SoundCloud, from a listener's own library — and finds
/// the words to it by matching on title, credit, release and running time. That
/// is what the SDK's decision to pass a whole track rather than an opaque id
/// makes possible, and it is the whole design.
///
/// The plugin is **pure Dart**. It depends on `swayve_plugin_sdk` and nothing
/// else — no Flutter, no HTTP client, no XML or HTML parser — because every
/// capability it needs is mediated by `SwayvePluginContext`. The LRC and TTML
/// parsers in `src/parsing/` are hand-written for that reason: a dependency
/// that brings its own transport cannot be used inside a permission model built
/// on a host-supplied one, and the parsers were cheaper to write than that hole
/// would be to close. See `README.md`.
///
/// One thing it deliberately does **not** do is romanize. A Japanese lyric
/// comes back in Japanese. Romanization needs a real dictionary, the packages
/// that hold one bring their own HTTP stack, and doing it in the host is both
/// where it belongs and the only place it can legally live given the transport
/// rule above.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'src/lyrics_plugin.dart';

export 'src/config.dart'
    show
        LyricsTimeouts,
        isAllowedHost,
        kBetterLyricsEndpoint,
        kBetterLyricsSource,
        kDurationTolerance,
        kLrcLibGetEndpoint,
        kLrcLibSearchEndpoint,
        kLrcLibSource,
        kLyricsAllowedHosts,
        kLyricsPluginId,
        kLyricsPluginName,
        kLyricsPluginVersion,
        kUserAgent;
export 'src/lyrics_client.dart' show LyricsClient;
export 'src/lyrics_plugin.dart' show LyricsPlugin;
export 'src/matching.dart'
    show
        LyricsMatch,
        LyricsQuery,
        durationsAgree,
        kLetterFolding,
        lightlyCleaned,
        lyricsRank,
        normalizeArtistForComparison,
        normalizeForComparison;
export 'src/parsing/lrc_parser.dart'
    show LrcLine, ParsedLrc, kFinalWordHold, parseLrc, plainFromLines;
export 'src/parsing/ttml_parser.dart' show ParsedTtml, parseTtml, parseTtmlTime;
export 'src/providers/lyrics_provider.dart' show LyricsProvider;
export 'src/sources/betterlyrics_source.dart' show BetterLyricsSource;
export 'src/sources/lrclib_source.dart' show LrcLibSource;
export 'src/sources/lyrics_source.dart'
    show LyricsSource, SourceAttempt, asPermittedBy;

/// Creates the lyrics plugin.
///
/// This is the single symbol a compiled plugin exposes, matching the
/// `SwayvePluginFactory` typedef. It is cheap, synchronous and free of side
/// effects: all real work belongs in `SwayvePlugin.initialize`.
///
/// The manifest's `entrypoint` is `lyrics`, which names this library and the
/// directory it lives in. It is not this function's name because Dart's own
/// lints require identifiers to be lowerCamelCase and a bare `lyrics()`
/// function would collide with the provider method it exists to reach.
SwayvePlugin createLyricsPlugin() => LyricsPlugin();
