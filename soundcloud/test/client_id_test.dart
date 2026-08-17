import 'package:soundcloud/soundcloud.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late FakeSwayveHttpClient http;
  late SoundCloudClient client;

  setUp(() {
    http = FakeSwayveHttpClient();
    client = SoundCloudClient(
      http: FakeSwayvePluginContext(
        permissions: const <SwayvePermission>{SwayvePermission.network},
        http: http,
      ).http,
      timeouts: fastTimeouts,
    );
  });

  group('scraping', () {
    test('finds a client_id via the colon spelling', () async {
      enqueueClientIdScrape(http);
      http.enqueueJson(<String, Object?>{'collection': [], 'next_href': null});

      await client.search('tracks', 'test', limit: 10);

      final Uri last = http.requests.last.url;
      expect(last.queryParameters['client_id'], 'fake-client-id-123');
    });

    test('finds a client_id via the query-string spelling', () async {
      http
        ..enqueueText(clientIdPageHtml)
        ..enqueueText('window.__sc_hydration.push({client_id=anotherid456});');
      http.enqueueJson(<String, Object?>{'collection': [], 'next_href': null});

      await client.search('tracks', 'test', limit: 10);

      final Uri last = http.requests.last.url;
      expect(last.queryParameters['client_id'], 'anotherid456');
    });

    test('tries scripts from last to first, recovering from a decoy trailing script', () async {
      http.enqueueText(
        '<html><body>'
        '<script src="https://a-v2.sndcdn.com/assets/app.js"></script>'
        '<script src="https://a-v2.sndcdn.com/assets/analytics.js"></script>'
        '</body></html>',
      );
      // The last script (analytics.js) has no client_id.
      http.enqueueText('window.ga("send", "pageview");');
      // The one before it (app.js) does.
      http.enqueueText(clientIdScriptBody);
      http.enqueueJson(<String, Object?>{'collection': [], 'next_href': null});

      await client.search('tracks', 'test', limit: 10);

      final Uri last = http.requests.last.url;
      expect(last.queryParameters['client_id'], 'fake-client-id-123');
    });

    test('no matching script or pattern is a clean unavailable error', () async {
      http.enqueueText('<html><body>no scripts here</body></html>');

      await expectLater(
        client.track(1),
        throwsA(isA<SoundCloudClientIdException>()),
      );
    });
  });

  group('401 recovery', () {
    test('a 401 clears the cached id, re-scrapes, and retries exactly once', () async {
      enqueueClientIdScrape(http);
      http.enqueueResponse(const SwayveHttpResponse(statusCode: 401));
      enqueueClientIdScrape(http);
      http.enqueueJson(<String, Object?>{'id': 1, 'title': 'Recovered'});

      final Map<String, Object?>? track = await client.track(1);

      expect(track?['title'], 'Recovered');
      // page fetch, script fetch, first (401'd) api call, page fetch, script
      // fetch, retried api call.
      expect(http.requests, hasLength(6));
    });

    test('a second 401 after the retry is reported, not looped', () async {
      enqueueClientIdScrape(http);
      http.enqueueResponse(const SwayveHttpResponse(statusCode: 401));
      enqueueClientIdScrape(http);
      http.enqueueResponse(const SwayveHttpResponse(statusCode: 401));

      await expectLater(
        client.track(1),
        throwsA(isA<SwayvePluginException>()),
      );
      // Exactly two api attempts, not an unbounded retry loop.
      final int apiCalls = http.requests
          .where((r) => r.url.host == 'api-v2.soundcloud.com')
          .length;
      expect(apiCalls, 2);
    });
  });

  group('caching', () {
    test('concurrent callers before the first scrape share one fetch', () async {
      enqueueClientIdScrape(http);
      http.enqueueJson(<String, Object?>{'id': 1, 'title': 'A'});
      http.enqueueJson(<String, Object?>{'id': 2, 'title': 'B'});

      final results = await Future.wait([client.track(1), client.track(2)]);

      expect(results[0]?['title'], 'A');
      expect(results[1]?['title'], 'B');
      // One page + one script + two api calls, not two full scrapes.
      expect(http.requests, hasLength(4));
    });
  });
}
