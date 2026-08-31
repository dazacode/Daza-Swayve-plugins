import 'package:lyrics/lyrics.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The manifest is what the user approves and the validator checks; the code is
/// what actually runs. When they disagree, the permissions the user granted are
/// not the permissions the code assumes — so every constant the plugin keeps a
/// copy of is compared against `plugin.json` here.
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
      expect(kLyricsPluginId, manifest['id']);
      expect(kLyricsPluginName, manifest['name']);
      expect(kLyricsPluginVersion.toString(), manifest['version']);
      expect(kLyricsAllowedHosts, manifestHosts);
    });

    test('it declares exactly one capability and one permission', () {
      expect(
        manifestCapabilities,
        <SwayveCapability>{SwayveCapability.lyrics},
        reason: 'A lyrics-only plugin that grew a second capability has '
            'become something else, and the permission screen a person '
            'already agreed to no longer describes it.',
      );
      expect(
        manifestPermissions,
        <SwayvePermission>{SwayvePermission.network},
        reason: 'Both services are keyless, so there is no secret to keep and '
            'therefore nothing for external_auth to guard.',
      );
    });

    test('it declares no source, because it has no catalogue', () {
      // Every other plugin in this repository publishes a browsable source.
      // This one answers questions about other plugins' tracks and appears
      // nowhere a listener browses, so a `source` block would be advertising a
      // shelf that does not exist.
      expect(manifest.containsKey('source'), isFalse);
    });

    test('it claims no media, because it serves none', () {
      final Map<String, Object?> media =
          manifest['media']! as Map<String, Object?>;
      expect(media['streamable'], isFalse);
      expect(media['downloadable'], isFalse);
      expect(
        media['offlineCache'],
        isFalse,
        reason: 'This flag is about the plugin keeping a cache of its own, '
            'which it does not — it has no filesystem access and wants none.',
      );
    });

    test('the endpoints it will actually call are on the declared hosts', () {
      // The constants are what get requested; the manifest is what the host
      // will permit. A new endpoint added on a host nobody declared is the
      // exact mistake this asserts against, and it is easy to make because the
      // URL looks fine on its own.
      for (final Uri endpoint in <Uri>[
        kLrcLibGetEndpoint,
        kLrcLibSearchEndpoint,
        kBetterLyricsEndpoint,
      ]) {
        expect(endpoint.scheme, 'https', reason: 'Plaintext for $endpoint.');
        expect(
          manifestAllowsHost(endpoint.host),
          isTrue,
          reason: '${endpoint.host} is not in plugin.json network.hosts '
              '($manifestHosts).',
        );
      }
    });

    test('every platform is declared, because nothing here is platform-bound',
        () {
      // Pure computation and HTTP: no web view, no embedded player, no native
      // channel. Unlike `youtube_music`, which excludes macOS because its
      // playback path needs an embed the host does not render there, this
      // plugin has no reason to leave a platform out — and leaving one out
      // would silently deny lyrics to a desktop listener.
      expect(
        (manifest['platforms']! as List<Object?>).cast<String>().toSet(),
        <String>{'android', 'ios', 'windows', 'linux', 'macos'},
      );
    });

    test('timeouts match the manifest', () {
      final Map<String, Object?> timeouts =
          manifest['timeouts']! as Map<String, Object?>;
      expect(
        LyricsTimeouts.manifest.request.inMilliseconds,
        timeouts['requestMs'],
      );
      expect(
        LyricsTimeouts.manifest.operation.inMilliseconds,
        timeouts['operationMs'],
      );
    });

    test('the entrypoint names the directory and the library', () {
      expect(manifest['entrypoint'], 'lyrics');
      expect(pluginRoot.path.split(RegExp(r'[\\/]')).last, 'lyrics');
      final String id = manifest['id']! as String;
      expect(id.split('.').last, manifest['entrypoint']);
    });

    test('it declares no settings, because there is nothing to configure', () {
      // No account, no region, no toggle. A setting exists to let somebody
      // change an answer; there is no answer here a person would want
      // different, and a preference nobody asked for is a support burden.
      expect(manifest.containsKey('settings'), isFalse);
    });
  });

  group('registration', () {
    test('registers exactly the capabilities it declares', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      expect(harness.context.registeredCapabilities, manifestCapabilities);
      expect(harness.context.lyricsProviders, hasLength(1));
      expect(harness.context.searchProviders, isEmpty);
      expect(harness.context.catalogProviders, isEmpty);
      expect(harness.context.metadataSearchProviders, isEmpty);
      expect(
        harness.context.visualsProviders,
        isEmpty,
        reason: '`visuals` is the capability next door — it also takes a whole '
            'track and also serves other plugins\' recordings — and this '
            'plugin deliberately does not declare it.',
      );
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
        LyricsPlugin().initialize(context),
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
      expect(harness.plugin.lyricsProvider, isNull);
      expect(harness.plugin.client, isNull);
      await harness.context.close();
    });

    test('the factory returns a fresh plugin', () {
      final SwayvePlugin first = createLyricsPlugin();
      final SwayvePlugin second = createLyricsPlugin();
      expect(first, isNot(same(second)));
      expect(first.identity.id, kLyricsPluginId);
    });
  });
}
