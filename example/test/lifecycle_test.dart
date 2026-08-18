// Lifecycle: what the host does to a plugin, in the order it does it.
//
// `load → initialize → registerProviders → active → dispose`. Everything the
// host is entitled to assume about those phases is asserted here.

import 'dart:convert';
import 'dart:io';

import 'package:swayve_plugin_example/example.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeSwayvePluginContext context;

  setUp(() {
    // The permission set a test grants should be the permission set the
    // manifest declares — here, nothing at all. That default is what turns
    // this suite into a permission audit rather than a formality.
    context = FakeSwayvePluginContext();
  });

  tearDown(() => context.close());

  test('the entrypoint returns a fresh, ready plugin', () {
    final first = example();
    final second = example();

    expect(first, isA<ExamplePlugin>());
    expect(identical(first, second), isFalse);
    // The factory must be usable before anything else has happened: the host
    // reads `identity` while deciding whether to load the plugin at all.
    expect(first.identity.id, 'app.swayve.plugins.example');
  });

  test('identity restates plugin.json exactly', () {
    final manifest =
        jsonDecode(_manifestFile().readAsStringSync()) as Map<String, Object?>;

    // `SwayvePluginIdentity.fromJson` reads the manifest's own field names, so
    // this compares the file the user approved against the object the running
    // code believes. A change to one that forgets the other fails here.
    expect(SwayvePluginIdentity.fromJson(manifest), ExamplePlugin().identity);
  });

  test('initialize registers exactly the declared capabilities', () async {
    final plugin = ExamplePlugin();

    await plugin.initialize(context);

    // Both directions: every capability has a provider, and no provider
    // exists for a capability the manifest never declared.
    expect(context.registeredCapabilities, plugin.identity.capabilities);
    expect(
      plugin.identity.capabilities,
      {SwayveCapability.search, SwayveCapability.catalog},
    );
    expect(context.searchProviders, hasLength(1));
    expect(context.catalogProviders, hasLength(1));
    expect(context.streamProviders, isEmpty);
    expect(context.artworkProviders, isEmpty);
    expect(context.playlistProviders, isEmpty);
    expect(context.authProviders, isEmpty);
  });

  test('initialize does no speculative work', () async {
    await ExamplePlugin().initialize(context);

    // Nothing was fetched, stored or asked of the user. `initialize` runs on
    // the host's startup path; a plugin that warms a cache there is a plugin
    // that makes the app slower to open.
    expect(context.fakeHttp.requests, isEmpty);
    expect(context.fakeStorage.entries, isEmpty);
    expect(context.fakeCredentials.secretKeys, isEmpty);
  });

  test('dispose is clean and idempotent', () async {
    final plugin = ExamplePlugin();
    await plugin.initialize(context);

    await plugin.dispose();
    await plugin.dispose();

    // The second call is a no-op rather than a second teardown: the host may
    // dispose a plugin it already disposed while shutting down.
    expect(
      context.fakeLogger.messages.where((line) => line.contains('disposed')),
      hasLength(1),
    );
  });

  test('dispose is safe when initialize never ran', () async {
    // A plugin whose `initialize` threw still gets disposed. Teardown must
    // survive a half-built object.
    await expectLater(ExamplePlugin().dispose(), completes);
  });
}

/// Locates `plugin.json` whether the suite was launched from the plugin
/// directory or from the repository root.
File _manifestFile() {
  for (final path in ['plugin.json', 'plugins/example/plugin.json']) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  fail('Could not find plugin.json from ${Directory.current.path}.');
}
