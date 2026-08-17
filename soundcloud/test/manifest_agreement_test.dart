import 'package:soundcloud/soundcloud.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The manifest is what the user approves and the validator checks; the code
/// is what actually runs. When they disagree, the permissions the user
/// granted are not the permissions the code assumes — so every constant the
/// plugin keeps a copy of is compared against `plugin.json` here.
void main() {
  group('code agrees with plugin.json', () {
    test('identity matches the manifest', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);
      final SwayvePluginIdentity identity = harness.plugin.identity;

      expect(identity.id, manifest['id']);
      expect(identity.name, manifest['name']);
      expect(identity.version.toString(), manifest['version']);
      expect(identity.swayvePluginApi, manifest['swayvePluginApi']);
      expect(identity.capabilities, manifestCapabilities);
      expect(identity.permissions, manifestPermissions);
    });

    test('constants match the manifest', () {
      expect(kSoundCloudPluginId, manifest['id']);
      expect(kSoundCloudPluginName, manifest['name']);
      expect(kSoundCloudPluginVersion.toString(), manifest['version']);
      expect(kSoundCloudAllowedHosts, manifestHosts);
    });

    test('timeouts match the manifest', () {
      final Map<String, Object?> timeouts =
          manifest['timeouts']! as Map<String, Object?>;
      expect(
        SoundCloudTimeouts.manifest.request.inMilliseconds,
        timeouts['requestMs'],
      );
      expect(
        SoundCloudTimeouts.manifest.operation.inMilliseconds,
        timeouts['operationMs'],
      );
    });

    test('the manifest states what the plugin promises about media', () {
      final Map<String, Object?> media = manifest['media']! as Map<String, Object?>;
      expect(media['streamable'], isTrue);
      expect(
        media['downloadable'],
        isTrue,
        reason: 'The manifest states what is possible across the catalogue; '
            'individual tracks report their own SwayveAvailability.'
            'downloadable per the confirmed per-track policy — see '
            'stream_test.dart.',
      );
      expect(media['offlineCache'], isFalse);
    });

    test('the entrypoint names the directory and the library', () {
      expect(manifest['entrypoint'], 'soundcloud');
      expect(pluginRoot.path.split(RegExp(r'[\\/]')).last, 'soundcloud');
      final String id = manifest['id']! as String;
      expect(id.split('.').last, manifest['entrypoint']);
    });

    test('the region setting matches what the catalog provider reads', () {
      final List<Object?> settings = manifest['settings']! as List<Object?>;
      final Map<String, Object?> region = settings
          .cast<Map<String, Object?>>()
          .firstWhere((e) => e['id'] == kRegionSettingId);
      expect(region['type'], 'select');
      expect(region['default'], kDefaultRegion);
      final List<Object?> options = region['options']! as List<Object?>;
      expect(options, isNotEmpty);
    });
  });

  group('registration', () {
    test('registers exactly the capabilities it declares', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      expect(harness.context.registeredCapabilities, manifestCapabilities);
      expect(harness.context.searchProviders, hasLength(1));
      expect(harness.context.catalogProviders, hasLength(1));
      expect(harness.context.streamProviders, hasLength(1));
      expect(harness.context.artworkProviders, hasLength(1));
      expect(harness.context.playlistProviders, hasLength(1));
      expect(harness.context.authProviders, isEmpty);
      expect(harness.context.lyricsProviders, isEmpty);
      expect(harness.context.scrobbleProviders, isEmpty);
    });

    test('initialize makes no network request', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      expect(
        harness.http.requests,
        isEmpty,
        reason: 'A plugin that fetches during initialize puts itself on the '
            'app launch path.',
      );
    });

    test('initialize fails loudly without the network permission', () async {
      final FakeSwayvePluginContext context = FakeSwayvePluginContext(
        permissions: const <SwayvePermission>{},
      );
      addTearDown(context.close);

      await expectLater(
        SoundCloudPlugin().initialize(context),
        throwsA(
          isA<SwayvePermissionDeniedException>().having(
            (SwayvePermissionDeniedException e) => e.permission,
            'permission',
            SwayvePermission.network,
          ),
        ),
      );
    });

    test('dispose is safe twice and after use', () async {
      final PluginHarness harness = await PluginHarness.start();
      await harness.plugin.dispose();
      await harness.plugin.dispose();
      expect(harness.plugin.searchProvider, isNull);
      await harness.context.close();
    });

    test('the factory returns a fresh plugin', () {
      final SwayvePlugin first = createSoundCloudPlugin();
      final SwayvePlugin second = createSoundCloudPlugin();
      expect(first, isNot(same(second)));
      expect(first.identity.id, kSoundCloudPluginId);
    });
  });
}
