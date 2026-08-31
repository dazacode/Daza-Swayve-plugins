import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';
import 'package:youtube_music/youtube_music.dart';

import 'support.dart';

/// The fixtures here are real responses, trimmed.
///
/// `next_radio.json` is a live `/next` for `dQw4w9WgXcQ` cut from fifty rows
/// to twenty-two; `next_radio_continuation.json` is the page that its own
/// continuation token actually returned, cut to four;
/// `browse_related.json` is the `MPTR…` page the Related tab actually points
/// at, cut from six shelves' worth to four. Everything asserted below was
/// measured against the service rather than assumed about it.
void main() {
  late PluginHarness harness;

  const String seed = 'dQw4w9WgXcQ';
  final SwayveMediaId seedId = YouTubeMusicIds.mediaId(seed);

  setUp(() async {
    harness = await PluginHarness.start();
  });

  tearDown(() => harness.stop());

  Future<SwayveRadio> start() async {
    harness.http.enqueueJson(fixture('next_radio.json'));
    final SwayveRadio? radio = await harness.radio.startRadio(seedId);
    expect(radio, isNotNull);
    return radio!;
  }

  group('starting a station', () {
    test('asks the next endpoint for a station, not for a playlist', () async {
      await start();

      expect(harness.requestedUrls.single.host, 'music.youtube.com');
      expect(harness.requestedUrls.single.path, '/youtubei/v1/next');
      expect(harness.lastBody['videoId'], seed);
      expect(
        harness.lastBody['playlistId'],
        'RDAMVM$seed',
        reason: 'The `RDAMVM` prefix is what turns a video id into a station '
            'seeded by that recording.',
      );
      expect(harness.lastBody['params'], 'wAEB');
      expect(
        harness.lastBody.containsKey('isAudioOnly'),
        isFalse,
        reason: 'Measured against the live endpoint: sending it changes '
            'nothing — fifty MUSIC_VIDEO_TYPE_OMV rows come back either way. '
            'Audio-only is a client-side filter, so sending a flag that does '
            'not work would only suggest it does.',
      );
      expect(
        (harness.lastBody['context']! as Map<String, Object?>)['client'],
        isA<Map<String, Object?>>().having(
          (Map<String, Object?> client) => client['clientName'],
          'clientName',
          'WEB_REMIX',
        ),
      );
    });

    test('reports the station the service named, not the one we asked for',
        () async {
      final SwayveRadio radio = await start();

      expect(radio.id.value, 'RDAMVM$seed');
      expect(radio.seed, seedId);
      expect(radio.title, 'Never Gonna Give You Up Mix');
      expect(radio.artwork, isNotNull);
      expect(
        radio.extra['isInfinite'],
        isTrue,
        reason: '`playlistPanelRenderer.isInfinite` is served directly. '
            'Reading it beats inferring endlessness from the presence of a '
            'continuation, which would be a guess about a stated fact.',
      );
      expect(radio.extra['videoId'], seed);
      expect(radio.extra['playlistId'], 'RDAMVM$seed');
    });

    test('an album seed is wrapped as a collection station', () async {
      harness.http.enqueueJson(fixture('next_radio.json'));
      await harness.radio.startRadio(
        YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
      );
      expect(harness.lastBody['playlistId'], 'RDAMPLMPREb_9nqEki4ZLqI');
    });

    test('a VL-prefixed playlist seed does not become RDAMPLVL…', () async {
      harness.http.enqueueJson(fixture('next_radio.json'));
      await harness.radio.startRadio(
        YouTubeMusicIds.mediaId('VLPLZ4mM3wKuMh8'),
      );
      expect(
        harness.lastBody['playlistId'],
        'RDAMPLPLZ4mM3wKuMh8',
        reason: '`VL` is how a playlist is browsed, not part of its id.',
      );
    });

    test('a station id the service already minted is forwarded verbatim',
        () async {
      harness.http.enqueueJson(fixture('next_radio.json'));
      await harness.radio.startRadio(
        seedId,
        context: YouTubeMusicIds.mediaId('RDCLAK5uy_lvHI2Z7dSfpD5g8'),
      );
      expect(
        harness.lastBody['playlistId'],
        'RDCLAK5uy_lvHI2Z7dSfpD5g8',
        reason: 'A station id YouTube handed over beats one synthesised from '
            'a video id, so it is not wrapped a second time.',
      );
    });

    test('an artist cannot seed a station, and says so with null', () async {
      final SwayveRadio? radio = await harness.radio.startRadio(
        YouTubeMusicIds.mediaId('UCq3rGZ1Zs9d0dTqRPcJHXyA'),
      );
      expect(radio, isNull);
      expect(
        harness.http.requests,
        isEmpty,
        reason: 'The `next` endpoint wants a video or a playlist. Saying so '
            'without asking beats a request that cannot answer.',
      );
    });

    test('an id from another plugin is not ours to seed', () async {
      final SwayveRadio? radio = await harness.radio.startRadio(
        const SwayveMediaId('app.swayve.plugins.other', seed),
      );
      expect(radio, isNull);
      expect(harness.http.requests, isEmpty);
    });
  });

  group('paging a station', () {
    test('the first page is the one startRadio already paid for', () async {
      final SwayveRadio radio = await start();
      final int afterStart = harness.http.requests.length;

      final SwayvePage<SwayveTrack> page = await harness.radio.radioTracks(
        radio,
        SwayveBrowseRequest.first,
      );

      expect(
        harness.http.requests, // no second request
        hasLength(afterStart),
        reason: '`next` answers with the handle and the rows in one response, '
            'and there is nowhere on SwayveRadio to put the rows. Asking the '
            'service again thirty milliseconds later would be paying twice.',
      );
      expect(page.items.length, greaterThanOrEqualTo(20));
      expect(page.hasMore, isTrue);
    });

    test('the seed is dropped, because it comes back as element zero',
        () async {
      final SwayveRadio radio = await start();
      final SwayvePage<SwayveTrack> page = await harness.radio.radioTracks(
        radio,
        SwayveBrowseRequest.first,
      );

      expect(
        page.items.map((SwayveTrack track) => track.id.value),
        isNot(contains(seed)),
        reason: 'The panel is the queue and the queue starts with what is '
            'playing. A caller asking what comes next does not want it back.',
      );
      expect(
        page.items.map((SwayveTrack track) => track.id.value).toSet(),
        hasLength(page.items.length),
        reason: 'No duplicates either.',
      );
    });

    test('the continuation token is the radio one, not the browse one',
        () async {
      final SwayveRadio radio = await start();
      final SwayvePage<SwayveTrack> first = await harness.radio.radioTracks(
        radio,
        SwayveBrowseRequest.first,
      );

      expect(
        first.cursor,
        startsWith('CDISPhIL'),
        reason: 'Read from `continuations[0].nextRadioContinuationData`. A '
            'panel does not carry the `nextContinuationData` a browse does.',
      );

      harness.http.enqueueJson(fixture('next_radio_continuation.json'));
      final SwayvePage<SwayveTrack> second = await harness.radio.radioTracks(
        radio,
        SwayveBrowseRequest.first.next(first.cursor!),
      );

      expect(harness.lastBody['continuation'], first.cursor);
      expect(
        harness.lastBody.containsKey('videoId'),
        isFalse,
        reason: 'A continuation names the whole request that produced it. '
            'Re-stating the seed alongside it describes a different one.',
      );
      expect(second.items, isNotEmpty);
      expect(second.cursor, isNotNull);
      expect(second.cursor, isNot(first.cursor));
    });

    test('a radio with nothing to ask with ends rather than throwing',
        () async {
      final SwayvePage<SwayveTrack> page = await harness.radio.radioTracks(
        SwayveRadio(id: YouTubeMusicIds.mediaId('RDAMVM$seed')),
        SwayveBrowseRequest.first,
      );
      expect(page.items, isEmpty);
      expect(
        page.cursor,
        isNull,
        reason: 'An empty page with no cursor is how the SDK says a station '
            'is over, which is the honest answer for one that cannot be '
            'resumed.',
      );
    });
  });

  group('what a station row says about itself', () {
    test('a music-video station is filed as videos, not as songs', () async {
      final SwayveRadio radio = await start();
      final SwayvePage<SwayveTrack> page = await harness.radio.radioTracks(
        radio,
        SwayveBrowseRequest.first,
      );

      expect(
        page.items.every((SwayveTrack t) => t.kind == SwayveTrackKind.video),
        isTrue,
        reason: 'Every row of this real response carries '
            'MUSIC_VIDEO_TYPE_OMV. A host offering to separate songs from '
            'videos has nothing to separate them by unless this is mapped.',
      );
    });

    test('the byline is read as a credit, never as an album', () async {
      final SwayveRadio radio = await start();
      final SwayvePage<SwayveTrack> page = await harness.radio.radioTracks(
        radio,
        SwayveBrowseRequest.first,
      );
      final SwayveTrack track = page.items.first;

      expect(track.artists, isNotEmpty);
      expect(
        track.album,
        isNull,
        reason: 'A watch row reads "Artist • 1.8B views • 19M likes". A '
            'parser that took the second segment as an album would file this '
            'station under a record called "1.8B views".',
      );
      expect(
        page.items.expand((SwayveTrack t) => t.artists).map(
              (SwayveArtistRef ref) => ref.name,
            ),
        isNot(anyElement(contains('views'))),
      );
      expect(track.duration, isNotNull);
      expect(track.title, isNotEmpty);
    });

    test('a row that can seed its own station says so', () async {
      final SwayveRadio radio = await start();
      final SwayvePage<SwayveTrack> page = await harness.radio.radioTracks(
        radio,
        SwayveBrowseRequest.first,
      );

      expect(
        page.items.every((SwayveTrack track) => track.canSeedRadio),
        isTrue,
        reason: 'Read off the overflow menu\'s MIX endpoint, by icon rather '
            'than by its localized "Start mix" label.',
      );
      expect(
        page.items.first.extra['radioSeed'],
        isA<Map<String, Object?>>().having(
          (Map<String, Object?> json) => json['params'],
          'params',
          'wAEB',
        ),
      );
    });
  });

  group('audio-only', () {
    test('filters the videos out, which for this station is all of them',
        () async {
      final PluginHarness audioOnly = await PluginHarness.start(
        settings: const <String, Object?>{kIncludeVideosSettingId: false},
      );
      addTearDown(audioOnly.stop);

      audioOnly.http.enqueueJson(fixture('next_radio.json'));
      final SwayveRadio? radio = await audioOnly.radio.startRadio(seedId);

      expect(
        radio,
        isNotNull,
        reason: 'The station exists; it is this listener\'s filter that '
            'empties it, and that is not "no station".',
      );
      final SwayvePage<SwayveTrack> page = await audioOnly.radio.radioTracks(
        radio!,
        SwayveBrowseRequest.first,
      );
      expect(
        page.items,
        isEmpty,
        reason: 'Every row of this real response is _OMV. Filtering to '
            'MUSIC_VIDEO_TYPE_ATV therefore keeps nothing — which is exactly '
            'why `isAudioOnly: true` on the request would have been a lie.',
      );
      expect(
        page.cursor,
        isNotNull,
        reason: 'Empty with a cursor means "ask again", not "the station ran '
            'dry". The distinction is the whole reason the filter is safe.',
      );
    });

    test('the mapping itself is the only thing separating the two', () {
      expect(isAudioOnlyType('MUSIC_VIDEO_TYPE_ATV'), isTrue);
      expect(isAudioOnlyType(null), isTrue);
      expect(isAudioOnlyType('MUSIC_VIDEO_TYPE_OMV'), isFalse);
      expect(isAudioOnlyType('MUSIC_VIDEO_TYPE_UGC'), isFalse);

      expect(
        trackKindForMusicVideoType('MUSIC_VIDEO_TYPE_ATV'),
        SwayveTrackKind.song,
      );
      expect(
        trackKindForMusicVideoType('MUSIC_VIDEO_TYPE_OMV'),
        SwayveTrackKind.video,
      );
      expect(
        trackKindForMusicVideoType('MUSIC_VIDEO_TYPE_UGC'),
        SwayveTrackKind.video,
      );
      expect(
        trackKindForMusicVideoType('MUSIC_VIDEO_TYPE_SOMETHING_NEW'),
        SwayveTrackKind.video,
      );
    });
  });

  group('related', () {
    test('goes through the Related tab, not through a second station',
        () async {
      harness.http
        ..enqueueJson(fixture('next_radio.json'))
        ..enqueueJson(fixture('browse_related.json'));

      final List<SwayveTrack> tracks = await harness.radio.related(seedId);

      expect(harness.http.requests, hasLength(2));
      expect(harness.requestedUrls[0].path, '/youtubei/v1/next');
      expect(harness.requestedUrls[1].path, '/youtubei/v1/browse');
      expect(
        harness.lastBody['browseId'],
        'MPTRt_6AEOVn4k62q',
        reason: 'Found by MUSIC_PAGE_TYPE_TRACK_RELATED, never by the tab '
            'title — "Related" is localized and the page type is not.',
      );
      expect(tracks, isNotEmpty);
      expect(
        tracks.every((SwayveTrack track) => track.kind == SwayveTrackKind.song),
        isTrue,
        reason: 'The "You might also like" shelf is art tracks: real audio '
            'recordings, unlike the station itself.',
      );
      expect(
        tracks.map((SwayveTrack track) => track.id.value),
        isNot(contains(seed)),
      );
    });

    test('the related browse id is found by page type', () {
      expect(
        relatedBrowseIdOf(fixtureMap('next_radio.json')),
        'MPTRt_6AEOVn4k62q',
      );
      expect(
        relatedBrowseIdOf(const <String, Object?>{}),
        isNull,
      );
    });

    test('a response with no Related tab is an empty answer, not an error',
        () async {
      harness.http.enqueueJson(fixture('next_radio_continuation.json'));
      expect(await harness.radio.related(seedId), isEmpty);
    });

    test('a non-track id is an empty answer without a request', () async {
      expect(
        await harness.radio.related(
          YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
        ),
        isEmpty,
      );
      expect(harness.http.requests, isEmpty);
    });
  });

  group('the parser on its own', () {
    test('parses the panel without a provider around it', () {
      final ParsedWatchQueue queue = parseWatchQueue(
        fixtureMap('next_radio.json'),
        what: 'test',
        seedVideoId: seed,
      );
      expect(queue.tracks.length, greaterThanOrEqualTo(20));
      expect(queue.playlistId, 'RDAMVM$seed');
      expect(queue.isInfinite, isTrue);
      expect(queue.cursor, isNotNull);
      expect(queue.automix, isNull);
    });

    test('a body with no panel is malformed, not empty', () {
      expect(
        () => parseWatchQueue(
          const <String, Object?>{'contents': <String, Object?>{}},
          what: 'test',
        ),
        throwsA(isA<SwayvePluginMalformedResponseException>()),
      );
    });
  });
}
