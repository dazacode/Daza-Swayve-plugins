import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';
import 'package:youtube_music/youtube_music.dart';

import 'support.dart';

SwayveHostInfo _host({Set<SwayveWebEmbedKind> embeds = const {}}) =>
    SwayveHostInfo(
      swayveVersion: const Version(1, 1, 0),
      swayvePluginApi: 1,
      platform: SwayvePlatform.android,
      supportedEmbeds: embeds,
      locale: 'en-GB',
      region: 'GB',
    );

void main() {
  final SwayveMediaId trackId = YouTubeMusicIds.mediaId('kJQP7kiw5Fk');

  group('playback resolves to a web embed', () {
    test('returns an embed the host can render', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(source.kind, SwayvePlayableKind.webEmbed);
      expect(source.isWebEmbed, isTrue);
      expect(source.uri, isNull);
      expect(source.embed, isNotNull);
      expect(source.embed!.kind, SwayveWebEmbedKind.inAppWebView);
      expect(source.embed!.uri.host, 'www.youtube.com');
      expect(source.embed!.uri.path, '/embed/kJQP7kiw5Fk');
      expect(source.embed!.uri.queryParameters['enablejsapi'], '1');
      expect(source.embed!.controls, contains(SwayveEmbedControl.play));
      expect(source.embed!.controls, contains(SwayveEmbedControl.pause));
    });

    test('resolving costs no network request', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);

      await harness.stream.resolvePlayback(trackId);

      expect(
        harness.http.requests,
        isEmpty,
        reason: 'resolvePlayback sits on the play path and is called again '
            'whenever a source expires.',
      );
    });

    test('an iframe-only host gets an iframe embed', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.iframe}),
      );
      addTearDown(harness.stop);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

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
          await harness.stream.resolvePlayback(trackId);

      expect(source.embed!.kind, SwayveWebEmbedKind.inAppWebView);
    });
  });

  group('resolved sources never claim a download right', () {
    test('availability is streamable and nothing more', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);

      expect(source.availability.streamable, isTrue);
      expect(
        source.availability.downloadable,
        isFalse,
        reason: 'An embed is a page to render, not bytes to keep. The '
            'manifest says downloadable: false and the resolved source must '
            'agree with it.',
      );
      expect(source.availability.onDevice, isFalse);
      expect(source.expiresIn, isNull);
    });

    test('it agrees with the manifest media block', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);

      final SwayvePlayableSource source =
          await harness.stream.resolvePlayback(trackId);
      final Map<String, Object?> media =
          manifest['media']! as Map<String, Object?>;

      expect(source.availability.streamable, media['streamable']);
      expect(source.availability.downloadable, media['downloadable']);
    });
  });

  group('it refuses rather than degrading', () {
    test('a host with no embed support gets unsupported', () async {
      final PluginHarness harness = await PluginHarness.start(host: _host());
      addTearDown(harness.stop);

      await expectLater(
        harness.stream.resolvePlayback(trackId),
        throwsA(isA<SwayvePluginUnsupportedException>()),
      );
    });

    test('hints that forbid an embed get unsupported', () async {
      final PluginHarness harness = await PluginHarness.start(
        host: _host(embeds: const {SwayveWebEmbedKind.inAppWebView}),
      );
      addTearDown(harness.stop);

      await expectLater(
        harness.stream.resolvePlayback(
          trackId,
          hints: const SwayvePlaybackHints(allowWebEmbed: false),
        ),
        throwsA(isA<SwayvePluginUnsupportedException>()),
      );
    });

    test('a non-track id gets unsupported, not a broken embed', () async {
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
  });
}
