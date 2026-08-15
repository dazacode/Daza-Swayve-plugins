import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';
import 'package:youtube_music/youtube_music.dart';

import 'support.dart';

/// The manifest is what the user approves and the validator checks; the code
/// is what actually runs. When they disagree, the permissions the user granted
/// are not the permissions the code assumes — so every constant the plugin
/// keeps a copy of is compared against `plugin.json` here.
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
      expect(kYouTubeMusicPluginId, manifest['id']);
      expect(kYouTubeMusicPluginName, manifest['name']);
      expect(kYouTubeMusicPluginVersion.toString(), manifest['version']);
      expect(kYouTubeMusicAllowedHosts, manifestHosts);
    });

    test('timeouts match the manifest', () {
      final Map<String, Object?> timeouts =
          manifest['timeouts']! as Map<String, Object?>;
      expect(
        YouTubeMusicTimeouts.manifest.request.inMilliseconds,
        timeouts['requestMs'],
      );
      expect(
        YouTubeMusicTimeouts.manifest.operation.inMilliseconds,
        timeouts['operationMs'],
      );
    });

    test('the manifest promises streaming and downloads', () {
      final Map<String, Object?> media =
          manifest['media']! as Map<String, Object?>;
      expect(media['streamable'], isTrue);
      expect(
        media['downloadable'],
        isTrue,
        reason: 'Audio resolves to a direct media address, which is bytes a '
            'host can keep. This was `false` while playback was embed-only, '
            'and changing it was a deliberate policy decision — see the class '
            'comment on YouTubeMusicStreamProvider. The two must agree, and '
            'stream_test.dart holds the resolved source to the same figure.',
      );
      expect(
        media['offlineCache'],
        isFalse,
        reason: 'Downloads are the host keeping a file it fetched. This flag '
            'is about the *plugin* keeping a cache of its own, which it does '
            'not — it has no filesystem access and wants none.',
      );
    });

    test('the media servers are declared', () {
      expect(
        manifestHosts,
        contains('*.googlevideo.com'),
        reason: 'A resolved audio address points at a rotating edge host. The '
            'specific name is chosen per request by YouTube, so a wildcard is '
            'the only honest way to declare it.',
      );
      expect(kYouTubeMusicAllowedHosts, containsAll(manifestHosts));
      expect(manifestHosts, containsAll(kYouTubeMusicAllowedHosts));
    });

    test('the entrypoint names the directory and the library', () {
      expect(manifest['entrypoint'], 'youtube_music');
      expect(pluginRoot.path.split(RegExp(r'[\\/]')).last, 'youtube_music');
      final String id = manifest['id']! as String;
      expect(id.split('.').last, manifest['entrypoint']);
    });

    test('the region setting matches what the client reads', () {
      final List<Object?> settings = manifest['settings']! as List<Object?>;
      final Map<String, Object?> region =
          settings.first! as Map<String, Object?>;
      expect(region['id'], 'region');
      expect(region['type'], 'select');
      expect(region['default'], 'US');
      final List<Object?> options = region['options']! as List<Object?>;
      expect(options, isNotEmpty);
    });
  });

  group('registration', () {
    test('registers exactly the capabilities it declares', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      expect(
        harness.context.registeredCapabilities,
        // `webview` is the one capability in the v1 vocabulary with no
        // provider interface behind it — the host renders the embed, so
        // there is nothing for the plugin to register. Every other declared
        // capability must have a provider, and no provider may be registered
        // for a capability that was not declared.
        manifestCapabilities.difference(
          const <SwayveCapability>{SwayveCapability.webview},
        ),
      );
      expect(harness.context.searchProviders, hasLength(1));
      expect(harness.context.catalogProviders, hasLength(1));
      expect(harness.context.streamProviders, hasLength(1));
      expect(harness.context.artworkProviders, hasLength(1));
      expect(harness.context.authProviders, isEmpty);
      expect(harness.context.lyricsProviders, isEmpty);
      expect(harness.context.scrobbleProviders, isEmpty);
      expect(harness.context.playlistProviders, isEmpty);
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
        permissions: const <SwayvePermission>{SwayvePermission.webview},
      );
      addTearDown(context.close);

      await expectLater(
        YouTubeMusicPlugin().initialize(context),
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
      final SwayvePlugin first = createYouTubeMusicPlugin();
      final SwayvePlugin second = createYouTubeMusicPlugin();
      expect(first, isNot(same(second)));
      expect(first.identity.id, kYouTubeMusicPluginId);
    });
  });
}
