import 'dart:convert';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';
import 'package:visuals/visuals.dart';

SwayveTrack _track({
  String title = 'ALIEN SUPERSTAR',
  String artist = 'Beyonce',
  Duration? duration = const Duration(seconds: 216),
}) =>
    SwayveTrack(
      id: const SwayveMediaId('local', 'x'),
      title: title,
      artists: <SwayveArtistRef>[SwayveArtistRef(name: artist)],
      duration: duration,
    );

Object _searchHit({
  String name = 'ALIEN SUPERSTAR',
  String artist = 'Beyonce',
  int durationMs = 216000,
  String uri = 'spotify:track:abc',
}) =>
    <String, Object?>{
      'uri': uri,
      'name': name,
      'duration_ms': durationMs,
      'artists': <Object?>[
        <String, Object?>{'name': artist},
      ],
    };

Object _searchBody(List<Object> items) => <String, Object?>{
      'tracks': <String, Object?>{'items': items},
    };

List<int> _canvasResponse({
  String url = 'https://canvaz.scdn.co/upload/artist/a/video/b.cnvs.mp4',
  String trackUri = 'spotify:track:abc',
}) {
  final List<int> body = <int>[
    0x12,
    ..._delimited(url),
    0x2a,
    ..._delimited(trackUri),
  ];
  return <int>[0x0a, ..._varint(body.length), ...body];
}

List<int> _delimited(String value) {
  final List<int> bytes = utf8.encode(value);
  return <int>[..._varint(bytes.length), ...bytes];
}

List<int> _varint(int value) {
  final List<int> out = <int>[];
  int remaining = value;
  while (remaining >= 0x80) {
    out.add((remaining & 0x7F) | 0x80);
    remaining >>= 7;
  }
  return out..add(remaining);
}

/// Queues the two responses every successful lookup needs before the canvas:
/// the server clock, then the minted token.
void _enqueueAuth(FakeSwayveHttpClient http) {
  http
    ..enqueueJson(<String, Object?>{'serverTime': 1767000000})
    ..enqueueJson(<String, Object?>{
      'accessToken': 'token-123',
      'accessTokenExpirationTimestampMs':
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    });
}

void main() {
  late FakeSwayveHttpClient http;
  late SpotifyTokenSource tokens;
  late SpotifyCanvasClient client;

  SpotifyTokenSource sourceFor(String? spDc) => SpotifyTokenSource(
        http: http,
        spDc: () => spDc,
      );

  setUp(() {
    http = FakeSwayveHttpClient();
    tokens = sourceFor('cookie-value');
    client = SpotifyCanvasClient(http: http, tokens: tokens);
  });

  tearDown(() => http.cancelHangs());

  group('SpotifyTokenSource', () {
    test('is unconfigured until a cookie is provided', () {
      expect(sourceFor(null).isConfigured, isFalse);
      expect(sourceFor('').isConfigured, isFalse);
      expect(sourceFor('   ').isConfigured, isFalse);
      expect(sourceFor('sp').isConfigured, isTrue);
    });

    test('sends the cookie only to open.spotify.com, and only to mint', () {
      _enqueueAuth(http);
      http
        ..enqueueJson(_searchBody(<Object>[_searchHit()]))
        ..enqueueResponse(
          SwayveHttpResponse(statusCode: 200, bodyBytes: _canvasResponse()),
        );

      return client.canvas(_track()).then((_) {
        for (final RecordedHttpRequest request in http.requests) {
          if (request.headers.containsKey('cookie')) {
            expect(request.url.host, 'open.spotify.com');
          }
        }
        // The search and canvas calls carry the bearer token instead.
        final canvasRequest = http.requests.last;
        expect(canvasRequest.headers['cookie'], isNull);
        expect(canvasRequest.headers['authorization'], 'Bearer token-123');
      });
    });

    test('names the TOTP version it computed the code under', () async {
      _enqueueAuth(http);
      http
        ..enqueueJson(_searchBody(const <Object>[]))
        ..enqueueResponse(const SwayveHttpResponse(statusCode: 404));
      await client.canvas(_track());

      final RecordedHttpRequest mint = http.requests[1];
      expect(mint.url.path, '/api/token');
      expect(mint.url.queryParameters['totpVer'], '$kSpotifyTotpVersion');
      expect(mint.url.queryParameters['totp'], hasLength(kTotpDigits));
      // Both parameters carry the server-derived code, so a device with a
      // skewed clock still mints successfully.
      expect(
        mint.url.queryParameters['totp'],
        mint.url.queryParameters['totpServer'],
      );
    });

    test('a settings override replaces the embedded version', () {
      final overridden = SpotifyTokenSource(
        http: http,
        spDc: () => 'cookie',
        totpVersion: () => '77',
      );
      expect(overridden.totpVersion, 77);
    });

    test('an empty or nonsense override falls back to the embedded version',
        () {
      for (final String? value in <String?>[null, '', '  ', 'latest', '0']) {
        expect(
          SpotifyTokenSource(
            http: http,
            spDc: () => 'cookie',
            totpVersion: () => value,
          ).totpVersion,
          kSpotifyTotpVersion,
        );
      }
    });

    test('a rejected cookie is an auth failure, not a malformed response',
        () async {
      http
        ..enqueueJson(<String, Object?>{'serverTime': 1767000000})
        ..enqueueJson(<String, Object?>{}, statusCode: 401);
      await expectLater(
        tokens.token(),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
    });

    test('a 200 with no access token is still an auth failure', () async {
      // What the endpoint actually does when it dislikes the cookie.
      _enqueueAuth(http);
      http.reset();
      http
        ..enqueueJson(<String, Object?>{'serverTime': 1767000000})
        ..enqueueJson(<String, Object?>{'isAnonymous': true});
      await expectLater(
        tokens.token(),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
    });

    test('caches the token across lookups', () async {
      _enqueueAuth(http);
      expect(await tokens.token(), 'token-123');
      // No further responses queued: a second call that tried to mint again
      // would fail on the empty queue.
      expect(await tokens.token(), 'token-123');
      expect(http.requests, hasLength(2));
    });

    test('an unreachable clock falls back to the local one', () async {
      http
        ..enqueueError()
        ..enqueueJson(<String, Object?>{'accessToken': 'token-123'});
      expect(await tokens.token(), 'token-123');
    });

    test('invalidate forces the next call to mint again', () async {
      _enqueueAuth(http);
      await tokens.token();
      tokens.invalidate();
      http.enqueueJson(<String, Object?>{'accessToken': 'token-456'});
      expect(await tokens.token(), 'token-456');
    });
  });

  group('SpotifyCanvasClient', () {
    test('resolves a track, then returns its canvas as motion artwork',
        () async {
      _enqueueAuth(http);
      http
        ..enqueueJson(_searchBody(<Object>[_searchHit()]))
        ..enqueueResponse(
          SwayveHttpResponse(statusCode: 200, bodyBytes: _canvasResponse()),
        );

      final SwayveVisual? visual = await client.canvas(_track());
      expect(visual, isNotNull);
      expect(visual!.kind, SwayveVisualKind.motionArtwork);
      expect(visual.uri.host, 'canvaz.scdn.co');
      expect(visual.source, 'Spotify');
      expect(visual.loops, isTrue);
      // Canvases are authored portrait. The host lays out before the first
      // frame arrives, so this has to be reported rather than discovered.
      expect(visual.aspectRatio, closeTo(9 / 16, 0.001));
    });

    test('asks the search API with a field-qualified query', () async {
      _enqueueAuth(http);
      http
        ..enqueueJson(_searchBody(<Object>[_searchHit()]))
        ..enqueueResponse(
          SwayveHttpResponse(statusCode: 200, bodyBytes: _canvasResponse()),
        );
      await client.canvas(_track());

      final RecordedHttpRequest search = http.requests[2];
      expect(search.url.host, 'api.spotify.com');
      expect(search.url.queryParameters['type'], 'track');
      expect(search.url.queryParameters['q'], contains('track:'));
      expect(search.url.queryParameters['q'], contains('artist:'));
    });

    test('sends the resolved uri to the canvas endpoint as protobuf', () async {
      _enqueueAuth(http);
      http
        ..enqueueJson(
          _searchBody(<Object>[_searchHit(uri: 'spotify:track:xyz')]),
        )
        ..enqueueResponse(
          SwayveHttpResponse(
            statusCode: 200,
            bodyBytes: _canvasResponse(trackUri: 'spotify:track:xyz'),
          ),
        );
      await client.canvas(_track());

      final RecordedHttpRequest canvas = http.requests.last;
      expect(canvas.method, 'POST');
      expect(canvas.url, kSpotifyCanvasEndpoint);
      expect(canvas.headers['accept'], 'application/protobuf');
      expect(
        utf8.decode(canvas.body! as List<int>, allowMalformed: true),
        contains('spotify:track:xyz'),
      );
    });

    test('declines a search hit whose title disagrees', () async {
      _enqueueAuth(http);
      http.enqueueJson(
        _searchBody(<Object>[
          _searchHit(name: 'Something Else Entirely'),
        ]),
      );
      expect(await client.canvas(_track()), isNull);
      // The canvas endpoint was never reached, so nothing was consumed for it.
      expect(http.requests, hasLength(3));
    });

    test('declines a search hit whose artist disagrees', () async {
      _enqueueAuth(http);
      http.enqueueJson(
        _searchBody(<Object>[_searchHit(artist: 'Someone Else')]),
      );
      expect(await client.canvas(_track()), isNull);
    });

    test('declines a hit whose running time is far out', () async {
      // A live version or a remix under the same name — the case duration is
      // in the match rules for.
      _enqueueAuth(http);
      http.enqueueJson(_searchBody(<Object>[_searchHit(durationMs: 400000)]));
      expect(await client.canvas(_track()), isNull);
    });

    test('prefers the closest running time over search rank', () async {
      _enqueueAuth(http);
      http
        ..enqueueJson(
          _searchBody(<Object>[
            // Spotify ranks the radio edit first; the album version is what is
            // playing.
            _searchHit(durationMs: 200000, uri: 'spotify:track:radio'),
            _searchHit(durationMs: 216000, uri: 'spotify:track:album'),
          ]),
        )
        ..enqueueResponse(
          SwayveHttpResponse(
            statusCode: 200,
            bodyBytes: _canvasResponse(trackUri: 'spotify:track:album'),
          ),
        );
      await client.canvas(_track());
      expect(
        utf8.decode(
          http.requests.last.body! as List<int>,
          allowMalformed: true,
        ),
        contains('spotify:track:album'),
      );
    });

    test('an empty search result is null, not a failure', () async {
      _enqueueAuth(http);
      http.enqueueJson(_searchBody(const <Object>[]));
      expect(await client.canvas(_track()), isNull);
    });

    test('404 from the canvas endpoint means no canvas', () async {
      // The ordinary answer for most recordings.
      _enqueueAuth(http);
      http
        ..enqueueJson(_searchBody(<Object>[_searchHit()]))
        ..enqueueResponse(const SwayveHttpResponse(statusCode: 404));
      expect(await client.canvas(_track()), isNull);
    });

    test('a canvas naming a different track is not accepted', () async {
      _enqueueAuth(http);
      http
        ..enqueueJson(_searchBody(<Object>[_searchHit()]))
        ..enqueueResponse(
          SwayveHttpResponse(
            statusCode: 200,
            bodyBytes: _canvasResponse(trackUri: 'spotify:track:someone-else'),
          ),
        );
      expect(await client.canvas(_track()), isNull);
    });

    test('refuses to hand back media from a host outside the allowlist',
        () async {
      _enqueueAuth(http);
      http
        ..enqueueJson(_searchBody(<Object>[_searchHit()]))
        ..enqueueResponse(
          SwayveHttpResponse(
            statusCode: 200,
            bodyBytes: _canvasResponse(url: 'https://evil.example/x.mp4'),
          ),
        );
      await expectLater(
        client.canvas(_track()),
        throwsA(isA<SwayvePluginUnsupportedException>()),
      );
    });

    test('a 401 on the canvas call drops the cached token', () async {
      _enqueueAuth(http);
      http
        ..enqueueJson(_searchBody(<Object>[_searchHit()]))
        ..enqueueResponse(const SwayveHttpResponse(statusCode: 401));
      await expectLater(
        client.canvas(_track()),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
      // Proven by the next call minting again rather than reusing.
      http
        ..enqueueJson(<String, Object?>{'accessToken': 'token-fresh'})
        ..enqueueJson(_searchBody(const <Object>[]));
      expect(await client.canvas(_track()), isNull);
    });

    test('rate limiting is reported as such', () async {
      _enqueueAuth(http);
      http
        ..enqueueJson(_searchBody(<Object>[_searchHit()]))
        ..enqueueResponse(
          const SwayveHttpResponse(
            statusCode: 429,
            headers: <String, String>{'retry-after': '30'},
          ),
        );
      await expectLater(
        client.canvas(_track()),
        throwsA(isA<SwayvePluginRateLimitedException>()),
      );
    });
  });

  group('SpotifyCanvasVisualsSource', () {
    test('stands aside silently when no cookie was provided', () async {
      final unconfigured = sourceFor(null);
      final source = SpotifyCanvasVisualsSource(
        client: SpotifyCanvasClient(http: http, tokens: unconfigured),
        tokens: unconfigured,
      );
      expect(await source.visual(_track()), isNull);
      // Nothing was contacted at all: an add-on nobody switched on costs
      // nothing.
      expect(http.requests, isEmpty);
    });

    test('returns the canvas when one is configured and found', () async {
      _enqueueAuth(http);
      http
        ..enqueueJson(_searchBody(<Object>[_searchHit()]))
        ..enqueueResponse(
          SwayveHttpResponse(statusCode: 200, bodyBytes: _canvasResponse()),
        );
      final source = SpotifyCanvasVisualsSource(client: client, tokens: tokens);
      expect((await source.visual(_track()))?.source, 'Spotify');
    });

    test('an expired cookie falls through instead of failing the lookup',
        () async {
      // The whole point of the source ordering: a dead Spotify credential
      // must leave the TIDAL sources behind it able to answer.
      http
        ..enqueueJson(<String, Object?>{'serverTime': 1767000000})
        ..enqueueJson(<String, Object?>{}, statusCode: 401);
      final source = SpotifyCanvasVisualsSource(client: client, tokens: tokens);
      expect(await source.visual(_track()), isNull);
    });

    test('the provider falls through to a later source', () async {
      http
        ..enqueueJson(<String, Object?>{'serverTime': 1767000000})
        ..enqueueJson(<String, Object?>{}, statusCode: 401);
      final provider = SourceAgnosticVisualsProvider(<VisualsSource>[
        SpotifyCanvasVisualsSource(client: client, tokens: tokens),
        _StubSource(
          SwayveVisual(
            uri:
                Uri.parse('https://resources.tidal.com/videos/x/1280x1280.mp4'),
            kind: SwayveVisualKind.motionArtwork,
            source: 'TIDAL',
          ),
        ),
      ]);
      expect((await provider.visual(_track()))?.source, 'TIDAL');
    });
  });
}

class _StubSource implements VisualsSource {
  _StubSource(this.result);

  final SwayveVisual? result;

  @override
  Future<SwayveVisual?> visual(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  }) async =>
      result;
}
