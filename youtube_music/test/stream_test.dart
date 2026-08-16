import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart' show SwayveLogLevel;
import 'package:test/test.dart';
import 'package:youtube_music/youtube_music.dart';

import 'support.dart';

SwayveHostInfo _host({
  Set<SwayveWebEmbedKind> embeds = const {},
  SwayvePlatform platform = SwayvePlatform.android,
}) =>
    SwayveHostInfo(
      swayveVersion: const Version(1, 1, 0),
      swayvePluginApi: 1,
      platform: platform,
      supportedEmbeds: embeds,
      locale: 'en-GB',
      region: 'GB',
    );

/// The two responses a successful audio resolution needs, in order: the
/// visitor identity, then the player itself.
void _queueAudio(PluginHarness harness, {String player = 'player_ok.json'}) {
  harness.http
    ..enqueueJson(fixture('player_visitor_id.json'))
    ..enqueueJson(fixture(player));
}

/// The video hints: what the host sends when somebody asks to *watch*.
const SwayvePlaybackHints _watch = SwayvePlaybackHints(
  preferAudioOnly: false,
);

void main() {
  _embedDocumentTests();

  final SwayveMediaId trackId = YouTubeMusicIds.mediaId('kJQP7kiw5Fk');

  group('audio resolves to a direct media address', () {
    test('returns a playable URL on a declared host', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(source.kind, SwayvePlayableKind.directUrl);
      expect(source.isWebEmbed, isFalse);
      expect(source.embed, isNull);
      expect(source.uri, isNotNull);
      expect(manifestAllowsHost(source.uri!.host), isTrue);
    });

    test('an Opus-capable host gets the best rendition', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(platform: SwayvePlatform.android),
      );
      addTearDown(harness.stop);
      _queueAudio(harness);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(source.uri!.queryParameters['itag'], '251');
      expect(source.mimeType, 'audio/webm');
    });

    test('Apple platforms get AAC, which is the only one they can decode',
        () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(platform: SwayvePlatform.ios),
      );
      addTearDown(harness.stop);
      _queueAudio(harness);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(
        source.uri!.queryParameters['itag'],
        '140',
        reason: 'Opus in WebM is the higher-bitrate rendition and Apple\'s '
            'media stack cannot decode it. Preferring it there would hand back '
            'a source that produces silence.',
      );
      expect(source.mimeType, 'audio/mp4');
    });

    test('a bitrate ceiling is honoured', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness);

      final SwayvePlayableSource source = await harness.stream.resolvePlayback(
        trackId,
        hints: const SwayvePlaybackHints(maxBitrateKbps: 64),
      );

      expect(source.uri!.queryParameters['itag'], '139');
    });

    test('the source expires, and says so honestly', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(source.expiresIn, isNotNull);
      expect(
        source.expiresIn!.inSeconds,
        21540 - kStreamExpiryMargin.inSeconds,
        reason: 'The response states its own lifetime; the margin exists so a '
            'source cannot go stale between being handed over and being used.',
      );
    });

    test('it states how long the audio runs', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(
        source.duration,
        const Duration(seconds: 187),
        reason: 'The response states the length of the recording in the same '
            'breath as the address, and a host with no such figure has to ask '
            'its own engine once the media loads — which for a network source '
            'can be provisional while the stream buffers. Every other length '
            'this plugin knows is read off a line of display text, rounded at '
            'best and describing a different upload at worst.',
      );
    });

    test('a length that means nothing is not stated', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      final Map<String, Object?> body = Map<String, Object?>.from(
        fixture('player_ok.json')! as Map<String, Object?>,
      )..['videoDetails'] = <String, Object?>{'lengthSeconds': '0'};
      harness.http
        ..enqueueJson(fixture('player_visitor_id.json'))
        ..enqueueJson(body);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(
        source.duration,
        isNull,
        reason: 'A live stream reports zero, and zero is not a duration — it '
            'is the absence of one. Passing it on would have the host draw a '
            'scrubber permanently at its end.',
      );
    });

    test('it carries no headers of its own', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(
        source.headers,
        isEmpty,
        reason: 'The address carries its own signature. A user agent or a '
            'referer the service did not ask for is how a signed URL gets '
            'refused.',
      );
    });

    test('a duplicate itag is taken once', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(
        source.uri!.queryParameters['sig'],
        isNot('fixture-aac-drc'),
        reason: 'The fixture lists itag 140 twice — plain, then with loudness '
            'normalisation. The first is the one YouTube ranked higher.',
      );
    });

    test('the audio path and the manifest agree about downloads', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);
      final Map<String, Object?> media =
          manifest['media']! as Map<String, Object?>;

      expect(source.availability.streamable, media['streamable']);
      expect(source.availability.downloadable, media['downloadable']);
      expect(source.availability.onDevice, isFalse);
    });
  });

  group('the visitor identity', () {
    test('is minted before the first player request', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness);

      await harness.stream.resolvePlayback(trackId);

      expect(harness.requestedUrls, hasLength(2));
      expect(harness.requestedUrls.first.path, '/youtubei/v1/visitor_id');
      expect(harness.requestedUrls.last.path, '/youtubei/v1/player');
    });

    test('is reused rather than re-minted for a second track', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness);
      harness.http.enqueueJson(fixture('player_ok.json'));

      await harness.stream.resolvePlayback(trackId);
      await harness.stream
          .resolvePlayback(YouTubeMusicIds.mediaId('dQw4w9WgXcQ'));

      expect(
        harness.requestedUrls
            .where((Uri u) => u.path == '/youtubei/v1/visitor_id'),
        hasLength(1),
      );
    });

    test('reaches the wire on the player request', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness);

      await harness.stream.resolvePlayback(trackId);

      final Map<String, Object?> context =
          harness.lastBody['context']! as Map<String, Object?>;
      final Map<String, Object?> client =
          context['client']! as Map<String, Object?>;
      expect(client['visitorData'], isNotNull);
      expect(client['clientName'], kPlayerClientName);
    });

    test('a refused session is retried once with a fresh identity', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      harness.http
        ..enqueueJson(fixture('player_visitor_id.json'))
        ..enqueueJson(fixture('player_login_required.json'))
        ..enqueueJson(fixture('player_visitor_id.json'))
        ..enqueueJson(fixture('player_ok.json'));

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(source.kind, SwayvePlayableKind.directUrl);
      expect(
        harness.requestedUrls
            .where((Uri u) => u.path == '/youtubei/v1/visitor_id'),
        hasLength(2),
        reason: 'The recovery is a *different* identity, not the same request '
            'again — so the cached one has to be dropped first.',
      );
    });
  });

  group('watching resolves to the embedded player', () {
    test('returns an embed the host can render', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId, hints: _watch);

      expect(source.kind, SwayvePlayableKind.webEmbed);
      expect(source.uri, isNull);
      expect(source.embed!.kind, SwayveWebEmbedKind.inAppWebView);
      expect(source.embed!.uri.host, 'www.youtube.com');
      expect(source.embed!.uri.path, '/embed/kJQP7kiw5Fk');
      expect(source.embed!.uri.queryParameters['enablejsapi'], '1');
      expect(source.embed!.controls, contains(SwayveEmbedControl.play));
    });

    test('costs no network request', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);

      await harness.stream.resolvePlayback(trackId, hints: _watch);

      expect(
        harness.http.requests,
        isEmpty,
        reason: 'A host asking to watch wants the page. Asking YouTube for '
            'audio streams first would be a round trip spent on an answer '
            'about to be thrown away.',
      );
    });

    test('an iframe-only host gets an iframe embed', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.iframe}),
      );
      addTearDown(harness.stop);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId, hints: _watch);

      expect(source.embed!.kind, SwayveWebEmbedKind.iframe);
    });

    test('an in-app web view is preferred when both are offered', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(
          embeds: const {
            SwayveWebEmbedKind.iframe,
            SwayveWebEmbedKind.inAppWebView,
          },
        ),
      );
      addTearDown(harness.stop);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId, hints: _watch);

      expect(source.embed!.kind, SwayveWebEmbedKind.inAppWebView);
    });

    test('an embed never claims a download right', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId, hints: _watch);

      expect(source.availability.streamable, isTrue);
      expect(
        source.availability.downloadable,
        isFalse,
        reason: 'A page is not bytes to keep, whatever the manifest allows '
            'for the audio path. The SDK reads the resolved source as well as '
            'the manifest precisely so the two can differ per resolution.',
      );
      expect(source.expiresIn, isNull);
    });
  });

  group('it degrades rather than breaking', () {
    test('extraction being closed falls back to the embed', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);
      _queueAudio(harness, player: 'player_sabr_only.json');

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(
        source.kind,
        SwayvePlayableKind.webEmbed,
        reason: 'The day YouTube stops serving plain addresses to this '
            'client, the plugin has to become what it used to be rather than '
            'stop working.',
      );
    });

    test('extraction being closed is reported to the host log', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);
      _queueAudio(harness, player: 'player_sabr_only.json');

      await harness.stream.resolvePlayback(trackId);

      expect(
        harness.context.fakeLogger.at(SwayveLogLevel.warn),
        isNotEmpty,
        reason: 'Playback carries on through the embed and downloads quietly '
            'stop being possible. The log is the only evidence.',
      );
    });

    test('a host with no embed gets unavailable when extraction closes',
        () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness, player: 'player_sabr_only.json');

      await expectLater(
        harness.stream.resolvePlayback(trackId),
        throwsA(isA<SwayvePluginUnavailableException>()),
      );
    });

    test('a region-blocked track is unsupported, not unavailable', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness, player: 'player_unavailable.json');

      await expectLater(
        harness.stream.resolvePlayback(trackId),
        throwsA(
          isA<SwayvePluginUnsupportedException>().having(
            (SwayvePluginUnsupportedException e) => e.message,
            'message',
            contains('country'),
          ),
        ),
        reason: 'One song being blocked is a fact about that song. The host '
            'drops it and plays the rest of the queue; treating it as a '
            'source outage would stop the album.',
      );
    });
  });

  group('it refuses rather than degrading', () {
    test('a non-track id gets unsupported', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);

      await expectLater(
        harness.stream.resolvePlayback(
          YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
        ),
        throwsA(isA<SwayvePluginUnsupportedException>()),
      );
    });

    test('an id from another plugin gets unsupported', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);

      await expectLater(
        harness.stream.resolvePlayback(
          const SwayveMediaId('dev.someone.else.plugin', 'kJQP7kiw5Fk'),
        ),
        throwsA(isA<SwayvePluginUnsupportedException>()),
      );
    });

    test('wanting video while forbidding an embed still returns audio',
        () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);
      _queueAudio(harness);

      final SwayvePlayableSource source = await harness.stream.resolvePlayback(
        trackId,
        hints: const SwayvePlaybackHints(
          preferAudioOnly: false,
          allowWebEmbed: false,
        ),
      );

      expect(
        source.kind,
        SwayvePlayableKind.directUrl,
        reason: 'The SDK is explicit that every hint is soft except '
            'allowWebEmbed: a provider that cannot honour one returns its '
            'best available source rather than failing. The only video this '
            'plugin has is an embed, and embeds were forbidden — so the audio '
            'is the best available source, and refusing outright would be '
            'reading a preference as a requirement.',
      );
    });
  });
}

/// The adapter page, which is what lets a host draw its own transport over a
/// player the host knows nothing about.
void _embedDocumentTests() {
  group('the adapter page', () {
    String documentFor(String videoId) => youTubeEmbedDocument(
          videoId: videoId,
          origin: 'https://www.youtube.com',
        );

    test('it defines the bridge object the host calls', () {
      final String page = documentFor('kJQP7kiw5Fk');

      expect(page, contains('window.${SwayveEmbedBridge.objectName} ='));
      for (final String function in <String>[
        SwayveEmbedBridge.play,
        SwayveEmbedBridge.pause,
        SwayveEmbedBridge.seek,
        SwayveEmbedBridge.setMuted,
      ]) {
        expect(
          page,
          contains('$function:'),
          reason: 'A control the embed declares and the page does not define '
              'is a button that does nothing.',
        );
      }
    });

    test('it posts to the channel the host registers', () {
      expect(
        documentFor('kJQP7kiw5Fk'),
        contains('window.${SwayveEmbedBridge.channelName}.postMessage'),
      );
    });

    test("it turns the service's own controls off", () {
      final String page = documentFor('kJQP7kiw5Fk');

      expect(
        page,
        contains('controls: 0'),
        reason: 'Two sets of controls on one video disagree the moment either '
            'is touched, and the one underneath is the one nobody asked for.',
      );
      expect(page, contains('rel: 0'));
      expect(page, contains('iv_load_policy: 3'));
      expect(page, contains('playsinline: 1'));
    });

    test('it states the origin it is loaded under', () {
      expect(
        documentFor('kJQP7kiw5Fk'),
        contains('origin: "https://www.youtube.com"'),
        reason: 'The API refuses a frame whose stated origin disagrees with '
            'where it is running.',
      );
    });

    test('the video id is encoded, not interpolated', () {
      // Not a real id — YouTube's are eleven characters of [A-Za-z0-9_-] — but
      // this file writes JavaScript by concatenation, and the moment one value
      // is trusted the next one is too.
      final String page = documentFor('a"); evil(); //');

      expect(page, contains(r'videoId: "a\"); evil(); //"'));
    });

    test('the embed carries the page and its controls together', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);

      final SwayvePlayableSource source = await harness.stream.resolvePlayback(
        YouTubeMusicIds.mediaId('kJQP7kiw5Fk'),
        hints: _watch,
      );

      final SwayveWebEmbed embed = source.embed!;
      expect(embed.document, isNotNull);
      expect(embed.controls, isNotEmpty);
      expect(
        embed.isDrivable,
        isTrue,
        reason: 'Controls without a document is a promise with no way to keep '
            'it, and a document without controls declares nothing drivable.',
      );
    });
  });
}
