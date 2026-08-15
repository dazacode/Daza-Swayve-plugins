// The guard test: proof that this plugin lives inside the permissions it
// declared.
//
// `plugin.json` declares `"permissions": []`, so `FakeSwayvePluginContext` is
// constructed with nothing granted. The fake enforces that set through the
// same `SwayvePermissionEnforcement` mixin the real host uses — reaching for
// `context.http`, `context.storage`, `context.credentials` or
// `context.webView` throws `SwayvePermissionDeniedException` synchronously,
// right at the line that over-reached.
//
// So the assertion is simply: the whole lifecycle, plus every provider call,
// completes. If a future edit adds a network call "just for artwork", this
// test fails before the change reaches a user's phone — which is the entire
// reason the SDK ships fakes that enforce rather than fakes that permit.

import 'package:swayve_plugin_example/example.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

void main() {
  test('the plugin declares no permissions', () {
    expect(ExamplePlugin().identity.permissions, isEmpty);
  });

  test('the full lifecycle runs with nothing granted', () async {
    final context = FakeSwayvePluginContext(permissions: const {});
    final plugin = ExamplePlugin();

    Future<void> exerciseEverything() async {
      await plugin.initialize(context);

      final search = context.searchProviders.single;
      await search.search(const SwayveSearchQuery(text: 'iron'));

      final catalog = context.catalogProviders.single;
      await catalog.tracks(const SwayveBrowseRequest());
      await catalog.albums(const SwayveBrowseRequest());
      await catalog.artists(const SwayveBrowseRequest());
      await catalog.album(
        const SwayveMediaId(examplePluginId, 'album:low-tide-hours'),
      );
      await catalog.artist(
        const SwayveMediaId(examplePluginId, 'artist:nadia-okonkwo'),
      );

      await plugin.dispose();
    }

    await expectLater(exerciseEverything(), completes);

    // And nothing was reached for behind the guard, either.
    expect(context.fakeHttp.requests, isEmpty);
    expect(context.fakeStorage.entries, isEmpty);
    expect(context.fakeCredentials.secretKeys, isEmpty);

    await context.close();
  });

  test('the guard the previous test relies on is real', () async {
    // If the fake did not actually enforce, the test above would prove
    // nothing. This is the control: the same ungranted context refuses the
    // facilities this plugin never touches.
    final context = FakeSwayvePluginContext(permissions: const {});
    addTearDown(context.close);

    expect(
      () => context.http,
      throwsA(
        isA<SwayvePermissionDeniedException>().having(
          (error) => error.permission,
          'permission',
          SwayvePermission.network,
        ),
      ),
    );
    expect(
      () => context.storage,
      throwsA(isA<SwayvePermissionDeniedException>()),
    );
    expect(
      () => context.credentials,
      throwsA(isA<SwayvePermissionDeniedException>()),
    );
    expect(
      () => context.webView,
      throwsA(isA<SwayvePermissionDeniedException>()),
    );
  });
}
