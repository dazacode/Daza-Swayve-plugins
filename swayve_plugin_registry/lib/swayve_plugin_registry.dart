/// The single place a host app looks to find out which first-party Swayve
/// plugins it can activate.
///
/// A `runtime: compiled` plugin's Dart code has to be linked into the host
/// binary at build time — that is the whole reason it is safe on iOS (see
/// `docs/platforms.md` in the swayve-plugins repository). Something still has
/// to say *which* compiled plugins that is, and the naive answer — the host
/// app depending on each plugin package directly, with one more `path:`/git
/// dependency and one more import per plugin — does not scale: every new
/// first-party plugin would touch the host app's `pubspec.yaml` and its own
/// plugin-loading code, forever, growing without bound as the catalogue
/// grows. That is exactly the tight coupling the plugin architecture exists
/// to avoid.
///
/// Instead, this package is the one thing a host app depends on. It depends
/// on every first-party compiled plugin itself, and re-exports one flat
/// registry. Adding a new first-party plugin to the platform means adding it
/// **here** — one dependency, one map entry — never touching the host app.
/// A host app that wants the whole first-party catalogue needs exactly two
/// dependencies, permanently: `swayve_plugin_sdk` (the interfaces) and this
/// package (what's compiled in).
///
/// This does not, and cannot, help with *community* plugins: a `compiled`
/// third-party plugin still has to be linked in by whoever builds that
/// binary, because nothing can safely download and run arbitrary code on
/// iOS. What it solves is the part that was purely accidental complexity —
/// the first-party catalogue growing the host's dependency list one plugin
/// at a time.
library;

import 'package:ibroadcast/ibroadcast.dart'
    show createIBroadcastPlugin, kIBroadcastPluginId;
import 'package:lyrics/lyrics.dart' show createLyricsPlugin, kLyricsPluginId;
import 'package:visuals/visuals.dart'
    show createVisualsPlugin, kVisualsPluginId;
import 'package:soundcloud/soundcloud.dart'
    show createSoundCloudPlugin, kSoundCloudPluginId;
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:youtube_music/youtube_music.dart'
    show createYouTubeMusicPlugin, kYouTubeMusicPluginId;

/// Every first-party plugin this build of the registry package was compiled
/// against, keyed by the manifest `id` a `.swayveplugin` bundle declares.
///
/// A host looks a verified bundle's id up here after its own compatibility
/// checks pass. An id with no entry means the *registry* has nothing to
/// activate for it — not that the bundle is invalid — and should be reported
/// to the user as "this build does not include a compiled implementation of
/// this plugin", never as a validation failure.
///
/// To add a plugin: add it as a dependency in this package's `pubspec.yaml`
/// and add one line below. Nothing outside this package changes.
const Map<String, SwayvePluginFactory> firstPartyCompiledPlugins =
    <String, SwayvePluginFactory>{
  kYouTubeMusicPluginId: createYouTubeMusicPlugin,
  kSoundCloudPluginId: createSoundCloudPlugin,
  kIBroadcastPluginId: createIBroadcastPlugin,
  kLyricsPluginId: createLyricsPlugin,
  kVisualsPluginId: createVisualsPlugin,
};
