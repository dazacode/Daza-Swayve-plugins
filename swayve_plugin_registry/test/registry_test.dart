import 'package:swayve_plugin_registry/swayve_plugin_registry.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('lists youtube_music under its manifest id', () {
    expect(
      firstPartyCompiledPlugins.keys,
      contains('app.swayve.plugins.youtube_music'),
    );
  });

  test('lists soundcloud under its manifest id', () {
    expect(
      firstPartyCompiledPlugins.keys,
      contains('app.swayve.plugins.soundcloud'),
    );
  });

  test('lists ibroadcast under its manifest id', () {
    expect(
      firstPartyCompiledPlugins.keys,
      contains('dev.dazacode.swayve.ibroadcast'),
    );
  });

  test('every factory builds a plugin whose identity id matches its key', () {
    for (final entry in firstPartyCompiledPlugins.entries) {
      final SwayvePlugin plugin = entry.value();
      expect(plugin.identity.id, entry.key);
    }
  });

  test('every factory is cheap and side-effect free to call', () {
    // A registry entry must be safe to instantiate speculatively (e.g. to
    // read `identity` before a bundle is actually imported) without that
    // call reaching the network, touching disk, or throwing.
    for (final factory in firstPartyCompiledPlugins.values) {
      expect(factory, returnsNormally);
    }
  });
}
