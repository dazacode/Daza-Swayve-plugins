/// Shared scaffolding for this plugin's tests.
///
/// Two things here are load-bearing rather than convenient.
///
/// **The manifest is the source of truth.** [manifest] reads the real
/// `plugin.json`, and [PluginHarness] grants the fake context exactly the
/// permissions the manifest declares — not every permission. A plugin that
/// reached for a facility it never asked for therefore fails here, in the test
/// suite, rather than on a user's phone.
///
/// **No test touches the network.** Every response comes from a committed
/// fixture through `FakeSwayveHttpClient`, and every fixture in
/// `test/fixtures/` is a real answer from the real service, trimmed to the
/// first few lines of its lyric and otherwise unedited. `dart test` on a
/// machine with no connection must pass.
library;

import 'dart:convert';
import 'dart:io';

import 'package:lyrics/lyrics.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';

/// The plugin directory, found by walking up from the current directory until
/// a `plugin.json` appears.
///
/// Walking rather than assuming keeps the suite runnable from the repository
/// root as well as from the plugin directory.
Directory get pluginRoot {
  Directory directory = Directory.current;
  for (var depth = 0; depth < 6; depth++) {
    if (File('${directory.path}/plugin.json').existsSync()) return directory;
    final Directory candidate = Directory('${directory.path}/lyrics');
    if (File('${candidate.path}/plugin.json').existsSync()) return candidate;
    final Directory parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError('Could not locate plugin.json from ${Directory.current}');
}

Map<String, Object?>? _manifest;

/// The parsed `plugin.json`.
Map<String, Object?> get manifest => _manifest ??= jsonDecode(
      File('${pluginRoot.path}/plugin.json').readAsStringSync(),
    ) as Map<String, Object?>;

/// The hostnames the manifest declares under `network.hosts`.
List<String> get manifestHosts {
  final Map<String, Object?> network =
      manifest['network']! as Map<String, Object?>;
  return (network['hosts']! as List<Object?>).cast<String>();
}

/// The permissions the manifest declares, as SDK values.
Set<SwayvePermission> get manifestPermissions => <SwayvePermission>{
      for (final Object? name in manifest['permissions']! as List<Object?>)
        SwayvePermission.fromWire(name! as String)!,
    };

/// The capabilities the manifest declares, as SDK values.
Set<SwayveCapability> get manifestCapabilities => <SwayveCapability>{
      for (final Object? name in manifest['capabilities']! as List<Object?>)
        SwayveCapability.fromWire(name! as String)!,
    };

/// A committed fixture, decoded.
Object? fixture(String name) => jsonDecode(fixtureText(name));

/// A committed fixture as a JSON object.
Map<String, Object?> fixtureMap(String name) =>
    fixture(name)! as Map<String, Object?>;

/// A committed fixture, as raw text.
String fixtureText(String name) =>
    File('${pluginRoot.path}/test/fixtures/$name').readAsStringSync();

/// Whether [host] is covered by the manifest's own `network.hosts` list.
///
/// Deliberately re-implemented here from the manifest rather than delegated to
/// the plugin's `isAllowedHost`: a test that asked the plugin whether the
/// plugin was behaving would prove nothing.
bool manifestAllowsHost(String host) {
  final String candidate = host.toLowerCase();
  for (final String pattern in manifestHosts) {
    if (pattern.startsWith('*.')) {
      final String suffix = pattern.substring(1).toLowerCase();
      if (candidate.endsWith(suffix) && candidate.length > suffix.length) {
        return true;
      }
    } else if (candidate == pattern.toLowerCase()) {
      return true;
    }
  }
  return false;
}

/// Short test deadlines, so that proving a timeout fires costs milliseconds
/// rather than the manifest's twenty seconds.
const LyricsTimeouts fastTimeouts = LyricsTimeouts(
  request: Duration(milliseconds: 30),
  operation: Duration(milliseconds: 60),
);

/// The recording every test asks about: the one both fixtures were captured
/// for, spelled the way a *different* plugin would have published it.
///
/// The `(Official Video)` and the `- Topic` are not decoration on this
/// constant. They are what a YouTube Music track actually carries, and they are
/// the reason `matching.dart` exists — a test that asked about a track already
/// spelled the way LRCLIB spells it would be testing nothing.
SwayveTrack blindingLights({
  Duration? duration = const Duration(seconds: 200),
  String title = 'Blinding Lights (Official Video)',
  String artist = 'The Weeknd - Topic',
  String? album = 'After Hours',
}) =>
    SwayveTrack(
      // Minted by another plugin, on purpose: this provider must never read an
      // id it did not create, and a fixture that handed it one of its own would
      // hide it if it started to.
      id: const SwayveMediaId(
        'app.swayve.plugins.youtube_music',
        'track:4NRXx6U8ABQ',
      ),
      title: title,
      artists: <SwayveArtistRef>[SwayveArtistRef(name: artist)],
      album: album == null ? null : SwayveAlbumRef(title: album),
      duration: duration,
    );

/// An initialized plugin plus the fake host it is running against.
final class PluginHarness {
  PluginHarness._(this.plugin, this.context);

  /// Builds a harness and runs `initialize`.
  ///
  /// [permissions] defaults to exactly what `plugin.json` declares.
  static Future<PluginHarness> start({
    Set<SwayvePermission>? permissions,
    SwayveHostInfo? host,
    LyricsTimeouts timeouts = LyricsTimeouts.manifest,
  }) async {
    final FakeSwayvePluginContext context = FakeSwayvePluginContext(
      permissions: permissions ?? manifestPermissions,
      host: host,
    );
    final LyricsPlugin plugin = LyricsPlugin(timeouts: timeouts);
    await plugin.initialize(context);
    return PluginHarness._(plugin, context);
  }

  /// The plugin under test.
  final LyricsPlugin plugin;

  /// The fake host it was initialized against.
  final FakeSwayvePluginContext context;

  /// The scripted HTTP client behind `context.http`.
  FakeSwayveHttpClient get http => context.fakeHttp;

  /// The registered lyrics provider.
  LyricsProvider get lyrics => plugin.lyricsProvider!;

  /// Every request the plugin has made, as URLs.
  List<Uri> get requestedUrls =>
      http.requests.map((RecordedHttpRequest r) => r.url).toList();

  /// Queues the two responses a full lookup consumes: BetterLyrics is asked
  /// first and LRCLIB second.
  ///
  /// Spelled out as one call because the *order* is the thing a test most
  /// easily gets wrong, and a test that queued them the other way round would
  /// pass while proving the opposite of what it claims.
  void enqueueBetterLyricsThenLrcLib({
    required Object? betterLyrics,
    required int betterLyricsStatus,
    required Object? lrcLib,
    required int lrcLibStatus,
  }) {
    http
      ..enqueueJson(betterLyrics, statusCode: betterLyricsStatus)
      ..enqueueJson(lrcLib, statusCode: lrcLibStatus);
  }

  /// Tears everything down. Call it in a test's teardown.
  Future<void> stop() async {
    http.cancelHangs();
    await plugin.dispose();
    await context.close();
  }
}
