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

    test('the declared source matches the manifest, field for field', () {
      // The manifest is what somebody approves at import and what a host can
      // read before this plugin has ever run; the constant is what runs. A
      // source row drawn from one and populated by the other is exactly the
      // kind of quiet disagreement this whole file exists to catch.
      final Map<String, Object?> source =
          manifest['source']! as Map<String, Object?>;
      expect(source['sourceId'], kYouTubeMusicSource.sourceId);
      expect(source['displayName'], kYouTubeMusicSource.displayName);
      expect(source['iconName'], kYouTubeMusicSource.iconName);
      expect(
        (source['contentTypes']! as List<Object?>).cast<String>().toSet(),
        kYouTubeMusicSource.contentTypes
            .map((SwayveContentType type) => type.wireName)
            .toSet(),
      );
    });

    test('the source stands behind exactly the capabilities declared', () {
      // `canSearch` is read off the capability set rather than stored, which
      // is only worth anything if the set is the manifest's own. A second
      // place to say a source is searchable is a second place for it to be
      // wrong.
      expect(kYouTubeMusicSource.capabilities, manifestCapabilities);
      expect(kYouTubeMusicSource.canSearch, isTrue);
    });

    test('the source declares no availability, because a manifest cannot know',
        () {
      // Whether the service is answering right now is knowable only to a
      // running plugin. The manifest omits it and the constant carries the
      // default, which the plugin republishes when it learns better.
      final Map<String, Object?> source =
          manifest['source']! as Map<String, Object?>;
      expect(source.containsKey('availability'), isFalse);
      expect(kYouTubeMusicSource.availability, SwayveSourceAvailability.ready);
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

    /// The declared setting with this id. Looked up rather than indexed, so
    /// that adding a setting cannot break the assertions about another one.
    Map<String, Object?> setting(String id) {
      final List<Object?> settings = manifest['settings']! as List<Object?>;
      return settings
          .cast<Map<String, Object?>>()
          .firstWhere((Map<String, Object?> entry) => entry['id'] == id);
    }

    test('the region setting matches what the client reads', () {
      final Map<String, Object?> region = setting(kRegionSettingId);
      expect(region['type'], 'select');
      expect(region['default'], kDefaultRegion);
      final List<Object?> options = region['options']! as List<Object?>;
      expect(options, isNotEmpty);
    });

    test('the video setting matches what the search provider reads', () {
      final Map<String, Object?> videos = setting(kIncludeVideosSettingId);
      expect(videos['type'], 'bool');
      expect(videos['default'], kDefaultIncludeVideos);
    });

    test(
        'the session cookie setting is a secret, matching what the auth '
        'provider reads', () {
      final Map<String, Object?> cookie = setting(kSessionCookieSettingId);
      expect(
        cookie['type'],
        'secret',
        reason: 'A `secret` setting is what routes the value to the '
            'credential store instead of plugin settings — see '
            'docs/permissions.md.',
      );
      expect(cookie['label'], isNotEmpty);
      expect(cookie['description'], isNotEmpty);
      expect(
        cookie.containsKey('default'),
        isFalse,
        reason: 'A secret is entered by hand; the manifest has nothing to '
            'default it to.',
      );
    });

    test(
        'the page id setting is a secret, matching what the library '
        'provider reads', () {
      final Map<String, Object?> pageId = setting(kPageIdSettingId);
      expect(
        pageId['type'],
        'secret',
        reason: 'Same reasoning as the session cookie above — this goes to '
            'the credential store, not plugin settings.',
      );
      expect(pageId['label'], isNotEmpty);
      expect(pageId['description'], isNotEmpty);
      expect(
        pageId.containsKey('default'),
        isFalse,
        reason: 'A secret is entered by hand; the manifest has nothing to '
            'default it to.',
      );
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
      expect(harness.context.authProviders, hasLength(1));
      expect(harness.context.libraryProviders, hasLength(1));
      expect(harness.context.lyricsProviders, isEmpty);
      expect(harness.context.scrobbleProviders, isEmpty);
      expect(harness.context.playlistProviders, isEmpty);
      expect(harness.context.artistActivityProviders, isEmpty);
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
