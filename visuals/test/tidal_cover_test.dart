import 'dart:convert';
import 'dart:io';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';
import 'package:visuals/visuals.dart';

Object? _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync());

SwayveTrack _track({
  String title = 'ALIEN SUPERSTAR',
  String artist = 'Beyonce',
  String? album = 'RENAISSANCE',
  Duration? duration = const Duration(seconds: 216),
}) =>
    SwayveTrack(
      id: const SwayveMediaId('local', 'x'),
      title: title,
      artists: <SwayveArtistRef>[SwayveArtistRef(name: artist)],
      album: album == null ? null : SwayveAlbumRef(title: album),
      duration: duration,
    );

void main() {
  group('animatedCoverUri', () {
    test('splits the five id groups into path segments', () {
      expect(
        animatedCoverUri('b7899d25-11d5-40ad-a99e-0ae721dee412').toString(),
        'https://resources.tidal.com/videos/b7899d25/11d5/40ad/a99e/'
        '0ae721dee412/1280x1280.mp4',
      );
    });

    test('honours a requested edge length', () {
      expect(
        animatedCoverUri(
          'b7899d25-11d5-40ad-a99e-0ae721dee412',
          edge: 640,
        ).toString(),
        endsWith('/640x640.mp4'),
      );
    });

    test('declines an id that is not in the five-group form', () {
      expect(animatedCoverUri('not-a-cover'), isNull);
      expect(animatedCoverUri(''), isNull);
      expect(animatedCoverUri('b7899d25-11d5-40ad-a99e'), isNull);
      expect(animatedCoverUri('b7899d25-11d5-40ad-a99e-0ae7-extra'), isNull);
    });

    test('declines an id whose groups are not hexadecimal', () {
      // The id becomes a URL path, so anything that is not a plain hex group
      // has to be refused rather than escaped and requested.
      expect(animatedCoverUri('b7899d25-11d5-40ad-a99e-../../etc'), isNull);
      expect(animatedCoverUri('zzzzzzzz-11d5-40ad-a99e-0ae721dee412'), isNull);
    });
  });

  group('legacy catalog', () {
    late FakeSwayveHttpClient http;
    late TidalClient client;

    setUp(() {
      http = FakeSwayveHttpClient();
      client = TidalClient(http: http, region: 'US');
    });

    tearDown(() => http.cancelHangs());

    test('finds the cover for a matching recording', () async {
      http.enqueueJson(_fixture('legacy_search.json'));
      final SwayveVisual? visual = await client.legacyCover(_track());

      expect(visual, isNotNull);
      expect(visual!.kind, SwayveVisualKind.motionArtwork);
      expect(visual.source, 'TIDAL');
      expect(visual.loops, isTrue);
      // iOS refuses animated artwork whose aspect ratio it was not told, and
      // every cover at this path is square.
      expect(visual.aspectRatio, 1);
      expect(
        visual.uri.toString(),
        contains('resources.tidal.com/videos/b7899d25/11d5/40ad/a99e/'),
      );
    });

    test('sends the shared client token and asks for both shelves', () async {
      http.enqueueJson(_fixture('legacy_search.json'));
      await client.legacyCover(_track());

      final RecordedHttpRequest request = http.lastRequest!;
      expect(request.url.host, 'api.tidal.com');
      expect(request.url.queryParameters['types'], 'TRACKS,ALBUMS');
      expect(request.url.queryParameters['countryCode'], 'US');
      expect(request.headers['x-tidal-token'], isNotNull);
    });

    test('returns null when nothing carries a cover', () async {
      http.enqueueJson(_fixture('legacy_search_no_cover.json'));
      expect(await client.legacyCover(_track()), isNull);
    });

    test('declines a release by a different artist', () async {
      http.enqueueJson(_fixture('legacy_search.json'));
      // The same response, asked about somebody else's song. A wrong sleeve
      // moving behind the right track reads as a bug, so the artist has to
      // agree before anything else is considered.
      expect(
        await client.legacyCover(
          _track(
            title: 'Some Other Song',
            artist: 'A Completely Different Artist',
            album: 'A Different Record',
          ),
        ),
        isNull,
      );
    });

    test('declines when the track names a different album', () async {
      http.enqueueJson(_fixture('legacy_search.json'));
      expect(
        await client.legacyCover(
          _track(title: 'Unrelated Cut', album: 'COWBOY CARTER'),
        ),
        isNull,
      );
    });

    test('declines a duration too far from the recording', () async {
      http.enqueueJson(_fixture('legacy_search.json'));
      // Same title and artist, but three minutes longer: an extended mix or a
      // live take, not this recording.
      expect(
        await client.legacyCover(
          _track(album: null, duration: const Duration(seconds: 400)),
        ),
        isNull,
      );
    });

    test('raises the mapped exception for a rejected request', () async {
      http.enqueueJson(<String, Object?>{}, statusCode: 429);
      await expectLater(
        client.legacyCover(_track()),
        throwsA(isA<SwayvePluginRateLimitedException>()),
      );
    });
  });

  group('official catalog', () {
    late FakeSwayveHttpClient http;
    late TidalClient client;

    setUp(() {
      http = FakeSwayveHttpClient();
      client = TidalClient(http: http, region: 'US');
    });

    tearDown(() => http.cancelHangs());

    test('reads a cover out of the compounded album resource', () async {
      http.enqueueJson(_fixture('official_search.json'));
      final SwayveVisual? visual = await client.officialCover(
        _track(),
        accessToken: 'token',
      );

      expect(visual, isNotNull);
      expect(visual!.kind, SwayveVisualKind.motionArtwork);
      expect(http.lastRequest!.url.host, 'openapi.tidal.com');
      expect(http.lastRequest!.headers['authorization'], 'Bearer token');
    });

    test('returns null when the album names no cover', () async {
      // The expected answer if the v2 catalog turns out not to carry this
      // asset at all: no visual, no exception, and the credential-free source
      // behind this one still answers.
      http.enqueueJson(_fixture('official_search_no_cover.json'));
      expect(
        await client.officialCover(_track(), accessToken: 'token'),
        isNull,
      );
    });
  });

  group('token source', () {
    late FakeSwayveHttpClient http;

    setUp(() => http = FakeSwayveHttpClient());
    tearDown(() => http.cancelHangs());

    TidalTokenSource source({String? id = 'id', String? secret = 'secret'}) =>
        TidalTokenSource(
          http: http,
          clientId: () => id,
          clientSecret: () => secret,
        );

    test('mints a bearer token from the client credentials', () async {
      http.enqueueJson(<String, Object?>{
        'access_token': 'minted',
        'expires_in': 86400,
      });
      expect(await source().token(), 'minted');

      final RecordedHttpRequest request = http.lastRequest!;
      expect(request.url.toString(), 'https://auth.tidal.com/v1/oauth2/token');
      expect(request.body, 'grant_type=client_credentials');
      expect(
        request.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('id:secret'))}',
      );
    });

    test('reuses a live token rather than minting per lookup', () async {
      http.enqueueJson(<String, Object?>{
        'access_token': 'minted',
        'expires_in': 86400,
      });
      final TidalTokenSource tokens = source();
      expect(await tokens.token(), 'minted');
      expect(await tokens.token(), 'minted');
      expect(http.requests, hasLength(1));
    });

    test('mints once when several lookups race a cold start', () async {
      http.enqueueJson(<String, Object?>{
        'access_token': 'minted',
        'expires_in': 86400,
      });
      final TidalTokenSource tokens = source();
      final List<String> results = await Future.wait(<Future<String>>[
        tokens.token(),
        tokens.token(),
        tokens.token(),
      ]);
      expect(results, everyElement('minted'));
      expect(http.requests, hasLength(1));
    });

    test('mints again after invalidate', () async {
      http.enqueueJson(<String, Object?>{
        'access_token': 'first',
        'expires_in': 86400,
      });
      http.enqueueJson(<String, Object?>{
        'access_token': 'second',
        'expires_in': 86400,
      });
      final TidalTokenSource tokens = source();
      expect(await tokens.token(), 'first');
      tokens.invalidate();
      expect(await tokens.token(), 'second');
    });

    test('treats a rejected credential as an auth failure', () async {
      http.enqueueJson(<String, Object?>{}, statusCode: 401);
      await expectLater(
        source().token(),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
    });

    test('reports configuration state without making a request', () {
      expect(source().isConfigured, isTrue);
      expect(source(id: null, secret: null).isConfigured, isFalse);
      expect(source(id: null, secret: null).isHalfConfigured, isFalse);
      // Half a credential is somebody who tried and stopped, and is worth
      // distinguishing from somebody who never wanted the official API.
      expect(source(secret: null).isHalfConfigured, isTrue);
      expect(source(id: '  ').isConfigured, isFalse);
      expect(http.requests, isEmpty);
    });
  });

  group('source ordering', () {
    late FakeSwayveHttpClient http;

    setUp(() => http = FakeSwayveHttpClient());
    tearDown(() => http.cancelHangs());

    test('falls back to the free catalog when unconfigured', () async {
      final TidalClient client = TidalClient(http: http, region: 'US');
      final provider = SourceAgnosticVisualsProvider(<VisualsSource>[
        TidalOfficialVisualsSource(
          client: client,
          tokens: TidalTokenSource(
            http: http,
            clientId: () => null,
            clientSecret: () => null,
          ),
        ),
        TidalLegacyVisualsSource(client: client),
      ]);

      // Only the legacy search is queued: an unconfigured official source has
      // to stand aside without spending a request.
      http.enqueueJson(_fixture('legacy_search.json'));
      final SwayveVisual? visual = await provider.visual(_track());

      expect(visual, isNotNull);
      expect(http.requests, hasLength(1));
      expect(http.requests.single.url.host, 'api.tidal.com');
    });
  });
}
