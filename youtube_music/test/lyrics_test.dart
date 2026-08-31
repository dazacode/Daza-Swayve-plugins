import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';
import 'package:youtube_music/youtube_music.dart';

import 'support.dart';

/// `player_captions.json` is the captions half of a real player response for
/// `dQw4w9WgXcQ`, trimmed to three tracks with the (already expired)
/// signature scrubbed. `timedtext_transcript.xml` and `timedtext_srv3.xml`
/// are the first cues of the caption track that response actually points at,
/// in both renderings the endpoint serves.
void main() {
  late PluginHarness harness;

  final SwayveTrack track = SwayveTrack(
    id: YouTubeMusicIds.mediaId('dQw4w9WgXcQ'),
    title: 'Never Gonna Give You Up',
  );

  setUp(() async {
    harness = await PluginHarness.start();
  });

  tearDown(() => harness.stop());

  group('fetching', () {
    /// The `client` block of the request at [index].
    Map<String, Object?> clientAt(int index) =>
        ((harness.bodyAt(index)['context']! as Map<String, Object?>)['client']!)
            as Map<String, Object?>;

    test('asks the player endpoint as the first captions client', () async {
      harness.http
        ..enqueueJson(fixture('player_visitor_id.json'))
        ..enqueueJson(fixture('player_captions.json'))
        ..enqueueText(fixtureText('timedtext_transcript.xml'));

      final SwayveLyrics? lyrics = await harness.lyrics.lyrics(track);

      expect(lyrics, isNotNull);
      expect(harness.requestedUrls[1].path, '/youtubei/v1/player');
      expect(
        clientAt(1)['clientName'],
        kCaptionsClients.first.name,
        reason: 'Not WEB. Measured against the live endpoint, WEB answers '
            'UNPLAYABLE with no captions block at all — with a fresh visitor '
            'identity, on the current client version, and with a real page\'s '
            'own INNERTUBE_CONTEXT sent verbatim.',
      );
      expect(
        harness.http.requests,
        hasLength(3),
        reason: 'One client answered, so the rest of the chain is not walked.',
      );
    });

    test('leads with the same client streaming uses, deliberately', () {
      expect(
        kCaptionsClients.first.name,
        kPlayerClientName,
        reason: 'The identity playback already depends on is both the most '
            'likely to keep working and — the actual point — the one whose '
            'failure is impossible to miss. A captions-only client can be '
            'turned down and lyrics just quietly stop existing, because "no '
            'captions" is the ordinary answer for most recordings.',
      );
      expect(
        kCaptionsClients.map((YouTubeMusicClientIdentity c) => c.name),
        <String>['VISIONOS', 'ANDROID_VR', 'IOS'],
        reason: 'ANDROID_VR is second rather than first because it is on the '
            'way out: yt-dlp dropped it from its defaults in 2026.08.19 after '
            'months of misbehaviour.',
      );
      expect(
        kCaptionsClients.map((YouTubeMusicClientIdentity c) => c.name),
        isNot(contains('WEB')),
      );
      expect(
        kCaptionsClients.map((YouTubeMusicClientIdentity c) => c.name).toSet(),
        hasLength(kCaptionsClients.length),
      );
    });

    test('falls through a client that carries no captions', () async {
      harness.http
        ..enqueueJson(fixture('player_visitor_id.json'))
        // Answers OK — nothing is wrong — and simply has no captions block.
        // This is what a client that has been quietly turned down looks like
        // from here, and it is indistinguishable from a track that genuinely
        // has no captions until a second client says otherwise.
        ..enqueueJson(fixture('player_ok.json'))
        ..enqueueJson(fixture('player_captions.json'))
        ..enqueueText(fixtureText('timedtext_transcript.xml'));

      final SwayveLyrics? lyrics = await harness.lyrics.lyrics(track);

      expect(lyrics, isNotNull);
      expect(lyrics!.synced, hasLength(10));
      expect(harness.http.requests, hasLength(4));
      expect(clientAt(1)['clientName'], kCaptionsClients[0].name);
      expect(
        clientAt(2)['clientName'],
        kCaptionsClients[1].name,
        reason: 'The second link of the chain, asked as itself rather than as '
            'a retry of the first.',
      );
      expect(
        harness.http.requests[2].headers['x-youtube-client-version'],
        kCaptionsClients[1].version,
      );
      expect(
        clientAt(2).containsKey('deviceMake'),
        isFalse,
        reason: 'Each entry is sent as exactly the context measured to '
            'answer, and this one was proven without device fields. '
            'Inventing one would change the request that was tested.',
      );
      expect(
        harness.requestedUrls.where(
          (Uri url) => url.path == '/youtubei/v1/visitor_id',
        ),
        hasLength(1),
        reason: 'The visitor identity is minted once and reused down the '
            'chain, not re-minted per client.',
      );
    });

    test('falls through a client whose playability is not OK', () async {
      harness.http
        ..enqueueJson(fixture('player_visitor_id.json'))
        ..enqueueJson(fixture('player_unavailable.json'))
        ..enqueueJson(fixture('player_captions.json'))
        ..enqueueText(fixtureText('timedtext_transcript.xml'));

      expect(
        await harness.lyrics.lyrics(track),
        isNotNull,
        reason: 'A client that has been turned down answers 200 with a '
            'non-OK playabilityStatus — "The page needs to be reloaded" — '
            'rather than with an HTTP error the client layer would raise.',
      );
      expect(harness.http.requests, hasLength(4));
    });

    test('the caption fetch is a GET on a declared host', () async {
      harness.http
        ..enqueueJson(fixture('player_visitor_id.json'))
        ..enqueueJson(fixture('player_captions.json'))
        ..enqueueText(fixtureText('timedtext_transcript.xml'));
      await harness.lyrics.lyrics(track);

      final RecordedHttpRequest caption = harness.http.requests.last;
      expect(caption.method, 'GET');
      expect(caption.url.host, 'www.youtube.com');
      expect(caption.url.path, '/api/timedtext');
      expect(manifestAllowsHost(caption.url.host), isTrue);
      expect(
        caption.url.queryParameters.containsKey('fmt'),
        isFalse,
        reason: 'Stripped so the plain <transcript> rendering comes back. '
            'Both formats parse, so this is tidiness — but a URL that carries '
            'the parameter must not be handed on with it.',
      );
    });
  });

  group('what comes back', () {
    Future<SwayveLyrics?> fetch(String captionFixture) {
      harness.http
        ..enqueueJson(fixture('player_visitor_id.json'))
        ..enqueueJson(fixture('player_captions.json'))
        ..enqueueText(fixtureText(captionFixture));
      return harness.lyrics.lyrics(track);
    }

    test('synced lines, in order, with the plain text alongside', () async {
      final SwayveLyrics? lyrics = await fetch('timedtext_transcript.xml');

      expect(lyrics!.isSynced, isTrue);
      expect(lyrics.synced, hasLength(10));
      expect(lyrics.synced!.first.at, const Duration(milliseconds: 1360));
      expect(lyrics.synced![1].at, const Duration(milliseconds: 18640));
      expect(lyrics.plain, isNotNull);
      expect(lyrics.plain, contains('We\'re no strangers to love'));
      for (int i = 1; i < lyrics.synced!.length; i++) {
        expect(
          lyrics.synced![i].at >= lyrics.synced![i - 1].at,
          isTrue,
          reason: 'The SDK asks for ascending order.',
        );
      }
    });

    test('the double-escaped apostrophe is decoded, not left as &#39;',
        () async {
      final SwayveLyrics? lyrics = await fetch('timedtext_transcript.xml');
      expect(
        lyrics!.synced![1].text,
        '♪ We\'re no strangers to love ♪',
        reason: 'The <transcript> rendering escapes its content and then '
            'escapes the escapes: an apostrophe arrives as &amp;#39;, so one '
            'decoding pass leaves &#39; sitting in the middle of the line.',
      );
    });

    test('a cue wrapped for layout is one line, not two', () async {
      final SwayveLyrics? lyrics = await fetch('timedtext_transcript.xml');
      expect(lyrics!.synced![2].text, '♪ You know the rules and so do I ♪');
    });

    test('the srv3 rendering parses to the same thing', () async {
      final SwayveLyrics? lyrics = await fetch('timedtext_srv3.xml');
      expect(lyrics!.synced, hasLength(8));
      expect(lyrics.synced!.first.at, const Duration(milliseconds: 1360));
      expect(lyrics.synced![1].text, '♪ We\'re no strangers to love ♪');
    });

    test('it is honest about where the words came from', () async {
      final SwayveLyrics? lyrics = await fetch('timedtext_transcript.xml');
      expect(
        lyrics!.source,
        'YouTube captions',
        reason: 'A host may display the attribution, and somebody reading a '
            'transcript deserves to know that is what they are reading.',
      );
      expect(
        lyrics.words,
        isNull,
        reason: 'A caption cue is a line with a start and a duration. It says '
            'nothing about where one word ends, and the SDK treats "no word '
            'timing" and "no words" as different claims.',
      );
      expect(lyrics.hasWordTiming, isFalse);
    });
  });

  group('absent is normal', () {
    test('every client answering without captions is null, not an error',
        () async {
      harness.http.enqueueJson(fixture('player_visitor_id.json'));
      for (int i = 0; i < kCaptionsClients.length; i++) {
        harness.http.enqueueJson(fixture('player_ok.json'));
      }

      expect(await harness.lyrics.lyrics(track), isNull);
      expect(
        harness.http.requests,
        hasLength(1 + kCaptionsClients.length),
        reason: 'The whole chain is walked before this says no, and no '
            'caption URL means no caption fetch. Three requests to answer '
            '"no lyrics" is the price of not answering it forever by '
            'mistake.',
      );
    });

    test('a caption body with no cues is null, not empty lyrics', () async {
      harness.http
        ..enqueueJson(fixture('player_visitor_id.json'))
        ..enqueueJson(fixture('player_captions.json'))
        ..enqueueText('<?xml version="1.0"?><transcript></transcript>');

      expect(
        await harness.lyrics.lyrics(track),
        isNull,
        reason: 'The SDK wants null for "none found" so a host can tell it '
            'apart from "found, but blank".',
      );
    });

    test('a track from another plugin is not ours to answer for', () async {
      final SwayveLyrics? lyrics = await harness.lyrics.lyrics(
        const SwayveTrack(
          id: SwayveMediaId('app.swayve.plugins.other', 'abc'),
          title: 'Something Else',
        ),
      );
      expect(lyrics, isNull);
      expect(harness.http.requests, isEmpty);
    });
  });

  group('the caption parser on its own', () {
    test('reads both renderings', () {
      expect(
        parseCaptionLines(fixtureText('timedtext_transcript.xml')),
        hasLength(10),
      );
      expect(
        parseCaptionLines(fixtureText('timedtext_srv3.xml')),
        hasLength(8),
      );
    });

    test('an error page is no lines rather than an exception', () {
      expect(parseCaptionLines('<html><body>404</body></html>'), isEmpty);
      expect(parseCaptionLines(''), isEmpty);
    });
  });
}
