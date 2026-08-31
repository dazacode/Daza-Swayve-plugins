import 'package:lyrics/lyrics.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The end-to-end tests: a track from another plugin goes in, a lyric or
/// `null` comes out, and every response along the way is a real one the live
/// services actually sent.
void main() {
  group('the word-timed path', () {
    test('BetterLyrics answers and nothing else is asked', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http.enqueueJson(fixture('betterlyrics_ttml.json'));
      final SwayveLyrics? lyrics = await harness.lyrics.lyrics(
        blindingLights(),
      );

      expect(lyrics, isNotNull);
      expect(lyrics!.hasWordTiming, isTrue);
      expect(lyrics.source, kBetterLyricsSource);
      expect(
        harness.http.requests,
        hasLength(1),
        reason: 'Nothing outranks word timing, so there is no reason to ask '
            'LRCLIB as well. A second request here is a second request per '
            'track for every listener.',
      );
      expect(harness.requestedUrls.single.host, 'lyrics-api.boidu.dev');
    });

    test('it publishes synced lines and plain text alongside the words',
        () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http.enqueueJson(fixture('betterlyrics_ttml.json'));
      final SwayveLyrics lyrics =
          (await harness.lyrics.lyrics(blindingLights()))!;

      // The SDK asks a provider holding one form to publish the others: a host
      // with no karaoke view must not come away empty because the timing was
      // too good.
      expect(lyrics.isSynced, isTrue);
      expect(lyrics.plain, isNotNull);
      expect(lyrics.plain, contains('I been tryna call'));
    });

    test('it sends the parameter names the service actually documents',
        () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http.enqueueJson(fixture('betterlyrics_ttml.json'));
      await harness.lyrics.lyrics(blindingLights());

      final Uri url = harness.requestedUrls.single;
      expect(url.path, '/getLyrics');
      expect(url.queryParameters['s'], 'Blinding Lights');
      expect(
        url.queryParameters['a'],
        'The Weeknd',
        reason: 'The `- Topic` suffix must not reach the service: it is '
            'YouTube\'s marker for an auto-generated channel, not part of '
            'anybody\'s name, and no catalogue holds it.',
      );
      expect(url.queryParameters['al'], 'After Hours');
      expect(url.queryParameters['d'], '200');
    });
  });

  group('the synced path', () {
    test('BetterLyrics declines and LRCLIB answers', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http
        ..enqueueJson(
          fixture('betterlyrics_unauthorized.json'),
          statusCode: 401,
        )
        ..enqueueJson(fixture('lrclib_get.json'));

      final SwayveLyrics lyrics =
          (await harness.lyrics.lyrics(blindingLights()))!;

      expect(lyrics.source, kLrcLibSource);
      expect(lyrics.isSynced, isTrue);
      expect(lyrics.hasWordTiming, isFalse);
      expect(lyrics.synced!.first.text, 'Yeah');
      expect(lyrics.plain, startsWith('Yeah'));
      expect(harness.requestedUrls, hasLength(2));
      expect(harness.requestedUrls.last.host, 'lrclib.net');
      expect(harness.requestedUrls.last.path, '/api/get');
    });

    test('the exact-match request carries all four fields', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http
        ..enqueueJson(
          fixture('betterlyrics_unauthorized.json'),
          statusCode: 401,
        )
        ..enqueueJson(fixture('lrclib_get.json'));
      await harness.lyrics.lyrics(blindingLights());

      final Map<String, String> query =
          harness.requestedUrls.last.queryParameters;
      expect(query['track_name'], 'Blinding Lights');
      expect(query['artist_name'], 'The Weeknd');
      expect(query['album_name'], 'After Hours');
      expect(query['duration'], '200');
    });

    test('a record for the wrong cut is refused, even from /api/get', () async {
      // Measured against the live service: `/api/get` answers `200` with a
      // 261-second record when asked for a 260-second one, and answers `200`
      // with something of its own choosing when no duration is sent at all. So
      // a `200` is not self-evidently the right recording, and the response's
      // own fields are checked before it is believed.
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http
        ..enqueueJson(
          fixture('betterlyrics_unauthorized.json'),
          statusCode: 401,
        )
        ..enqueueJson(fixture('lrclib_get_wrong_cut.json'))
        // Rejecting the exact record sends the lookup on to the search
        // fallback, which is offered the same wrong-length candidates.
        ..enqueueJson(fixture('lrclib_search.json'));

      final SwayveLyrics? lyrics = await harness.lyrics.lyrics(
        blindingLights(),
      );
      expect(lyrics, isNotNull);
      for (final SwayveLyricLine line in lyrics!.synced!) {
        expect(line.at.inSeconds, lessThan(203));
      }
    });
  });

  group('the search fallback', () {
    test('a 404 from /api/get is not a failure, it is a second question',
        () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http
        ..enqueueJson(
          fixture('betterlyrics_unauthorized.json'),
          statusCode: 401,
        )
        ..enqueueJson(fixture('lrclib_not_found.json'), statusCode: 404)
        ..enqueueJson(fixture('lrclib_search.json'));

      final SwayveLyrics? lyrics = await harness.lyrics.lyrics(
        blindingLights(),
      );
      expect(lyrics, isNotNull);
      expect(lyrics!.source, kLrcLibSource);
      expect(harness.requestedUrls.last.path, '/api/search');
      expect(
        harness.requestedUrls.last.queryParameters.containsKey('duration'),
        isFalse,
        reason: 'The search endpoint does not filter on duration — that is '
            'what makes it a fallback and what makes this plugin adjudicate '
            'the results itself.',
      );
    });

    test('it refuses every candidate whose running time is wrong', () async {
      // The committed search fixture is four real records under one title and
      // one credit, running 202, 248, 200 and 263 seconds. Two of them are the
      // recording being played and two are compilation edits carrying the same
      // words with different timings.
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http
        ..enqueueJson(
          fixture('betterlyrics_unauthorized.json'),
          statusCode: 401,
        )
        ..enqueueJson(fixture('lrclib_not_found.json'), statusCode: 404)
        ..enqueueJson(fixture('lrclib_search.json'));

      final SwayveLyrics lyrics =
          (await harness.lyrics.lyrics(blindingLights()))!;
      // Both accepted candidates start their first line inside the first
      // fifteen seconds; the 248- and 263-second edits do not.
      expect(lyrics.synced!.first.at.inSeconds, lessThan(15));
    });

    test('nothing at all when every candidate is the wrong length', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http
        ..enqueueJson(
          fixture('betterlyrics_unauthorized.json'),
          statusCode: 401,
        )
        ..enqueueJson(fixture('lrclib_not_found.json'), statusCode: 404)
        ..enqueueJson(fixture('lrclib_search.json'));

      // A 320-second recording under the same title and credit: an extended
      // mix nobody has transcribed. Every fixture candidate is refused.
      final SwayveLyrics? lyrics = await harness.lyrics.lyrics(
        blindingLights(duration: const Duration(seconds: 320)),
      );
      expect(
        lyrics,
        isNull,
        reason: 'Better nothing than another edit\'s timings.',
      );
    });
  });

  group('saying no', () {
    test('nothing anywhere is null, not an exception', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http
        ..enqueueJson(
          fixture('betterlyrics_unauthorized.json'),
          statusCode: 401,
        )
        ..enqueueJson(fixture('lrclib_not_found.json'), statusCode: 404)
        ..enqueueJson(<Object?>[]);

      expect(await harness.lyrics.lyrics(blindingLights()), isNull);
    });

    test('an instrumental is a no, not a failure', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      final Map<String, Object?> record =
          Map<String, Object?>.of(fixtureMap('lrclib_instrumental.json'))
            // Re-credited so it passes the title and artist check and is
            // refused on `instrumental` alone, which is the thing under test.
            ..['trackName'] = 'Blinding Lights'
            ..['artistName'] = 'The Weeknd'
            ..['duration'] = 200.0;

      harness.http
        ..enqueueJson(
          fixture('betterlyrics_unauthorized.json'),
          statusCode: 401,
        )
        ..enqueueJson(record)
        ..enqueueJson(<Object?>[]);

      expect(await harness.lyrics.lyrics(blindingLights()), isNull);
    });

    test('a track with no credit costs no request at all', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      final SwayveTrack anonymous = SwayveTrack(
        id: const SwayveMediaId('app.swayve.plugins.soundcloud', '9'),
        title: 'Late Night Jam',
        duration: const Duration(seconds: 240),
      );

      expect(await harness.lyrics.lyrics(anonymous), isNull);
      expect(harness.http.requests, isEmpty);
    });
  });

  group('when a service is broken rather than empty', () {
    test('one source failing is invisible if the other answers', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http
        ..enqueueJson(fixture('betterlyrics_cache_only.json'), statusCode: 503)
        ..enqueueJson(fixture('lrclib_get.json'));

      final SwayveLyrics lyrics =
          (await harness.lyrics.lyrics(blindingLights()))!;
      expect(
        lyrics.source,
        kLrcLibSource,
        reason: 'The listener got their lyric. There is nothing for them to '
            'do about the other service, so nothing is reported.',
      );
    });

    test('every source failing is reported, because nothing was learned',
        () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http
        ..enqueueJson(fixture('betterlyrics_cache_only.json'), statusCode: 503)
        ..enqueueError();

      await expectLater(
        harness.lyrics.lyrics(blindingLights()),
        throwsA(isA<SwayvePluginUnavailableException>()),
      );
    });

    test('a rate limit is reported as one, with its retry window', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http
        ..enqueueResponse(
          SwayveHttpResponse.json(
            <String, Object?>{'error': 'Rate limit exceeded.'},
            statusCode: 429,
            headers: <String, String>{'retry-after': '30'},
          ),
        )
        ..enqueueError();

      await expectLater(
        harness.lyrics.lyrics(blindingLights()),
        throwsA(
          isA<SwayvePluginRateLimitedException>().having(
            (SwayvePluginRateLimitedException e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 30),
          ),
        ),
      );
    });

    test('a 401 is not reported as an authentication problem', () async {
      // There is no sign-in that would fix it — this plugin holds no key and
      // asks for none — so reporting one would send a listener looking for a
      // setting that does not exist.
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      harness.http
        ..enqueueJson(
          fixture('betterlyrics_unauthorized.json'),
          statusCode: 401,
        )
        ..enqueueJson(fixture('lrclib_not_found.json'), statusCode: 404)
        ..enqueueJson(<Object?>[]);

      expect(await harness.lyrics.lyrics(blindingLights()), isNull);
    });
  });

  group('deadlines and cancellation', () {
    test('a hung service loses to the operation deadline', () async {
      final PluginHarness harness =
          await PluginHarness.start(timeouts: fastTimeouts);
      addTearDown(harness.stop);

      harness.http.enqueueHang();

      await expectLater(
        harness.lyrics.lyrics(blindingLights()),
        throwsA(isA<SwayvePluginTimeoutException>()),
      );
    });

    test('the whole lookup shares one budget, not one per source', () async {
      final PluginHarness harness =
          await PluginHarness.start(timeouts: fastTimeouts);
      addTearDown(harness.stop);

      // Two hangs. If each source had its own budget the second would still be
      // waiting when the first gave up, and the call would take twice as long
      // as the manifest promised.
      harness.http
        ..enqueueHang()
        ..enqueueHang();

      final Stopwatch clock = Stopwatch()..start();
      await expectLater(
        harness.lyrics.lyrics(blindingLights()),
        throwsA(isA<SwayvePluginTimeoutException>()),
      );
      clock.stop();
      expect(
        clock.elapsed,
        lessThan(fastTimeouts.operation * 2),
      );
    });

    test('a cancelled lookup stops rather than finishing', () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      final SwayveCancellationTokenSource source =
          SwayveCancellationTokenSource();
      source.cancel();

      await expectLater(
        harness.lyrics.lyrics(blindingLights(), cancel: source.token),
        throwsA(isA<SwayvePluginCancelledException>()),
      );
      expect(
        harness.http.requests,
        isEmpty,
        reason: 'Cancelled before any work starts costs no request.',
      );
    });

    test('cancelling between sources stops the second one being asked',
        () async {
      final PluginHarness harness = await PluginHarness.start();
      addTearDown(harness.stop);

      final SwayveCancellationTokenSource source =
          SwayveCancellationTokenSource();
      harness.http.enqueueHang();

      final Future<SwayveLyrics?> pending = harness.lyrics.lyrics(
        blindingLights(),
        cancel: source.token,
      );
      source.cancel();

      await expectLater(
        pending,
        throwsA(isA<SwayvePluginCancelledException>()),
      );
      expect(harness.http.requests, hasLength(1));
    });
  });

  test('the provider reads nothing out of the track id', () async {
    // The id belongs to whichever plugin published the track and is opaque
    // here by design. Changing it must change nothing about the answer.
    final PluginHarness harness = await PluginHarness.start();
    addTearDown(harness.stop);

    harness.http
      ..enqueueJson(fixture('betterlyrics_ttml.json'))
      ..enqueueJson(fixture('betterlyrics_ttml.json'));

    final SwayveTrack fromYouTube = blindingLights();
    final SwayveTrack fromElsewhere = SwayveTrack(
      id: const SwayveMediaId('app.swayve.plugins.ibroadcast', '99177'),
      title: fromYouTube.title,
      artists: fromYouTube.artists,
      album: fromYouTube.album,
      duration: fromYouTube.duration,
    );

    expect(
      await harness.lyrics.lyrics(fromYouTube),
      await harness.lyrics.lyrics(fromElsewhere),
    );
    expect(harness.requestedUrls.first, harness.requestedUrls.last);
  });
}
