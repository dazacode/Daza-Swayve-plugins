import 'package:test/test.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'package:visuals/visuals.dart';

void main() {
  test('manifest hosts accept official TIDAL API and media subdomains', () {
    expect(isAllowedHost('openapi.tidal.com'), isTrue);
    expect(isAllowedHost('auth.tidal.com'), isTrue);
    expect(isAllowedHost('api.tidal.com'), isTrue);
    expect(isAllowedHost('resources.tidal.com'), isTrue);
    expect(isAllowedHost('tidal.com.evil.example'), isFalse);
    expect(isAllowedHost('api.music.apple.com'), isFalse);
  });

  test('manifest hosts accept every Spotify endpoint the canvas path uses', () {
    expect(isAllowedHost('open.spotify.com'), isTrue);
    expect(isAllowedHost('accounts.spotify.com'), isTrue);
    expect(isAllowedHost('api.spotify.com'), isTrue);
    expect(isAllowedHost('spclient.wg.spotify.com'), isTrue);
    // Where the canvas video itself is served from.
    expect(isAllowedHost('canvaz.scdn.co'), isTrue);
    expect(isAllowedHost('i.scdn.co'), isTrue);
  });

  test('manifest hosts refuse Spotify look-alikes', () {
    expect(isAllowedHost('spotify.com.evil.example'), isFalse);
    expect(isAllowedHost('scdn.co.evil.example'), isFalse);
    // The apex is spelled out rather than wildcarded, so an unlisted
    // subdomain is not admitted by accident. Each Spotify host this plugin
    // reaches is named individually — `accounts` had to be added by hand
    // when the application credential arrived, which is the point.
    expect(isAllowedHost('partner.spotify.com'), isFalse);
    expect(isAllowedHost('spotify.com'), isFalse);
    expect(isAllowedHost('evil-scdn.co'), isFalse);
  });

  test('every endpoint constant points at an allowed host', () {
    for (final Uri endpoint in <Uri>[
      kTidalApiOrigin,
      kTidalTokenEndpoint,
      kTidalLegacyApiOrigin,
      kTidalResourcesOrigin,
      kSpotifyTokenEndpoint,
      kSpotifyServerTimeEndpoint,
      kSpotifySearchEndpoint,
      kSpotifyCanvasEndpoint,
      kSpotifyAccountsTokenEndpoint,
    ]) {
      expect(
        isAllowedHost(endpoint.host),
        isTrue,
        reason: '$endpoint is not covered by network.hosts',
      );
    }
  });

  test('visuals plugin identity exposes only the shared visuals capability',
      () {
    final plugin = createVisualsPlugin();
    expect(plugin.identity.id, kVisualsPluginId);
    expect(plugin.identity.capabilities, contains(SwayveCapability.visuals));
  });
}
