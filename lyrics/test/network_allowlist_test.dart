import 'package:lyrics/lyrics.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The test that proves the plugin honours its own declaration.
///
/// `network.hosts` is what the user is shown and what the host enforces. It is
/// only meaningful if the plugin never tries to reach past it — and "never
/// tries" has to be demonstrated, not asserted in a README. So: drive the
/// provider down every path it has, then check every recorded request against
/// the hostnames the manifest itself declares.
///
/// The allowlist used here is read from `plugin.json` rather than from the
/// plugin's own `kLyricsAllowedHosts`. Asking the plugin whether the plugin is
/// behaving would prove nothing.
void main() {
  test('the manifest actually declares hosts', () {
    expect(manifestHosts, isNotEmpty);
    expect(
      manifestPermissions,
      contains(SwayvePermission.network),
      reason: 'A hosts list without the network permission is decoration.',
    );
  });

  test('every outbound request targets a declared host', () async {
    final PluginHarness harness = await PluginHarness.start();
    addTearDown(harness.stop);

    // The word-timed path: BetterLyrics answers and nothing else is asked.
    harness.http.enqueueJson(fixture('betterlyrics_ttml.json'));
    await harness.lyrics.lyrics(blindingLights());

    // The synced path: BetterLyrics declines, LRCLIB's exact endpoint answers.
    harness.http
      ..enqueueJson(fixture('betterlyrics_unauthorized.json'), statusCode: 401)
      ..enqueueJson(fixture('lrclib_get.json'));
    await harness.lyrics.lyrics(blindingLights());

    // The search fallback: both of LRCLIB's endpoints, which is the only path
    // that makes three requests.
    harness.http
      ..enqueueJson(fixture('betterlyrics_unauthorized.json'), statusCode: 401)
      ..enqueueJson(fixture('lrclib_not_found.json'), statusCode: 404)
      ..enqueueJson(fixture('lrclib_search.json'));
    await harness.lyrics.lyrics(blindingLights());

    expect(
      harness.http.requests,
      isNotEmpty,
      reason: 'A test that recorded nothing proves nothing.',
    );
    for (final RecordedHttpRequest request in harness.http.requests) {
      expect(
        request.url.scheme,
        'https',
        reason: 'Plaintext for ${request.url}.',
      );
      expect(
        manifestAllowsHost(request.url.host),
        isTrue,
        reason: '${request.url.host} is not in plugin.json network.hosts '
            '($manifestHosts). Request: ${request.method} ${request.url}',
      );
      expect(
        request.method,
        'GET',
        reason: 'This plugin reads and never writes. A POST from here would '
            'be submitting something to a service on a listener\'s behalf.',
      );
    }
  });

  test('every request identifies the plugin', () async {
    // Neither service asks for a key, and LRCLIB asks in its documentation for
    // a descriptive `User-Agent` instead. That header is the entire contract
    // this plugin has with two services giving it something for nothing, so it
    // is asserted rather than assumed — and asserted on *every* request, since
    // a new call site added without it would be the one that gets the plugin
    // blocked.
    final PluginHarness harness = await PluginHarness.start();
    addTearDown(harness.stop);

    harness.http
      ..enqueueJson(fixture('betterlyrics_unauthorized.json'), statusCode: 401)
      ..enqueueJson(fixture('lrclib_get.json'));
    await harness.lyrics.lyrics(blindingLights());

    expect(harness.http.requests, hasLength(2));
    for (final RecordedHttpRequest request in harness.http.requests) {
      expect(request.headers['user-agent'], kUserAgent);
      expect(
        kUserAgent,
        contains('github.com'),
        reason: 'LRCLIB asks for a link back, so that an operator seeing '
            'unusual traffic can find out whose it is.',
      );
    }
  });

  test('the plugin refuses to build a URL off the allowlist', () {
    for (final String host in manifestHosts) {
      expect(isAllowedHost(host), isTrue);
      expect(isAllowedHost(host.toUpperCase()), isTrue);
    }
    for (final String host in <String>[
      'evil.example.com',
      // The near-misses, which are the ones a naive `contains` would let
      // through and the ones an attacker would actually register.
      'lrclib.net.evil.example.com',
      'notlrclib.net',
      'boidu.dev',
      '',
    ]) {
      expect(
        isAllowedHost(host),
        isFalse,
        reason: '$host must not be treated as declared.',
      );
    }
  });

  test('the client refuses an undeclared host before making a request',
      () async {
    // The guard is not decoration: it turns a mistake in this plugin into an
    // exception naming this plugin, rather than into a transport failure from
    // the host that reads like an outage.
    final FakeSwayvePluginContext context = FakeSwayvePluginContext(
      permissions: manifestPermissions,
    );
    addTearDown(context.close);
    final LyricsClient client = LyricsClient(http: context.http);

    expect(
      () => client.get(
        Uri.parse('https://lyrics.example.com/getLyrics'),
        const <String, String?>{},
      ),
      throwsA(isA<SwayvePluginUnsupportedException>()),
    );
    expect(
      context.fakeHttp.requests,
      isEmpty,
      reason: 'Refused before the request, not after it.',
    );
  });
}
