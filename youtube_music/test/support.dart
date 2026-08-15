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
/// fixture through `FakeSwayveHttpClient`. `dart test` on a machine with no
/// connection must pass.
library;

import 'dart:convert';
import 'dart:io';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:youtube_music/youtube_music.dart';

/// The plugin directory, found by walking up from the current directory until
/// a `plugin.json` appears.
///
/// Walking rather than assuming keeps the suite runnable from the repository
/// root as well as from the plugin directory.
Directory get pluginRoot {
  Directory directory = Directory.current;
  for (var depth = 0; depth < 6; depth++) {
    if (File('${directory.path}/plugin.json').existsSync()) return directory;
    final Directory candidate =
        Directory('${directory.path}/plugins/youtube_music');
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
const YouTubeMusicTimeouts fastTimeouts = YouTubeMusicTimeouts(
  request: Duration(milliseconds: 30),
  operation: Duration(milliseconds: 60),
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
    Map<String, Object?> settings = const <String, Object?>{},
    YouTubeMusicTimeouts timeouts = YouTubeMusicTimeouts.manifest,
  }) async {
    final FakeSwayvePluginContext context = FakeSwayvePluginContext(
      permissions: permissions ?? manifestPermissions,
      host: host,
      settings: FakeSwayveSettingsView(settings),
    );
    final YouTubeMusicPlugin plugin = YouTubeMusicPlugin(timeouts: timeouts);
    await plugin.initialize(context);
    return PluginHarness._(plugin, context);
  }

  /// The plugin under test.
  final YouTubeMusicPlugin plugin;

  /// The fake host it was initialized against.
  final FakeSwayvePluginContext context;

  /// The scripted HTTP client behind `context.http`.
  FakeSwayveHttpClient get http => context.fakeHttp;

  /// The registered search provider.
  YouTubeMusicSearchProvider get search => plugin.searchProvider!;

  /// The registered catalog provider.
  YouTubeMusicCatalogProvider get catalog => plugin.catalogProvider!;

  /// The registered artwork provider.
  YouTubeMusicArtworkProvider get artwork => plugin.artworkProvider!;

  /// The registered stream provider.
  YouTubeMusicStreamProvider get stream => plugin.streamProvider!;

  /// Every request the plugin has made, as URLs.
  List<Uri> get requestedUrls =>
      http.requests.map((RecordedHttpRequest r) => r.url).toList();

  /// The decoded body of the most recent request.
  Map<String, Object?> get lastBody {
    final Object? body = http.lastRequest?.body;
    return body is Map<String, Object?> ? body : const <String, Object?>{};
  }

  /// Tears everything down. Call it in a test's teardown.
  Future<void> stop() async {
    await plugin.dispose();
    await context.close();
  }
}
