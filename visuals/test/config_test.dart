import 'package:test/test.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'package:visuals/visuals.dart';

void main() {
  test('manifest hosts accept official TIDAL API and media subdomains', () {
    expect(isAllowedHost('openapi.tidal.com'), isTrue);
    expect(isAllowedHost('resources.tidal.com'), isTrue);
    expect(isAllowedHost('api.music.apple.com'), isTrue);
    expect(isAllowedHost('tidal.com.evil.example'), isFalse);
  });

  test('visuals plugin identity exposes only the shared visuals capability',
      () {
    final plugin = createVisualsPlugin();
    expect(plugin.identity.id, kVisualsPluginId);
    expect(plugin.identity.capabilities, contains(SwayveCapability.visuals));
  });
}
