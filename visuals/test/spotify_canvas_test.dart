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

/// The application token, which a lookup mints first.
void _enqueueAppToken(FakeSwayveHttpClient http) => http.enqueueJson(
      <String, Object?>{'access_token': 'app-token', 'expires_in': 3600},
    );

/// The web-player token, minted only once a search has matched.
///
/// Two responses, because the clock is asked first so a device whose time is
/// wrong still produces a code Spotify accepts.
void _enqueueWebToken(FakeSwayveHttpClient http) {
  http
    ..enqueueJson(<String, Object?>{'serverTime': 1767000000})
    ..enqueueJson(<String, Object?>{
      'accessToken': 'web-token',
      'isAnonymous': false,
      'accessTokenExpirationTimestampMs':
          DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    });
}

void main() {
  late FakeSwayveHttpClient http;
  late SpotifyTokenSource tokens;
  late SpotifyAppTokenSource appTokens;
  late SpotifyCanvasClient client;

  SpotifyTokenSource webSource(String? spDc) =>
      SpotifyTokenSource(http: http, spDc: () => spDc);

  SpotifyAppTokenSource appSource(String? id, String? secret) =>
      SpotifyAppTokenSource(
        http: http,
        clientId: () => id,
        clientSecret: () => secret,
      );

  setUp(() {
    http = FakeSwayveHttpClient();
    tokens = webSource('cookie-value');
    appTokens = appSource('client-id', 'client-secret');
    client = SpotifyCanvasClient(
      http: http,
      tokens: tokens,
      appTokens: appTokens,
    );
  });

  tearDown(() => http.cancelHangs());

  group('SpotifyAppTokenSource', () {
    test('needs both halves before it counts as configured', () {
      expect(appSource(null, null).isConfigured, isFalse);
      expect(appSource('id', null).isConfigured, isFalse);
      expect(appSource('id', '  ').isConfigured, isFalse);
      expect(appSource('id', 'secret').isConfigured, isTrue);
    });

    test('half a credential is somebody who tried', () {
      expect(appSource('id', null).isHalfConfigured, isTrue);
      expect(appSource(null, null).isHalfConfigured, isFalse);
      expect(appSource('id', 'secret').isHalfConfigured, isFalse);
    });

    test('mints from the accounts endpoint with basic auth', () async {
      _enqueueAppToken(http);
      expect(await appTokens.token(), 'app-token');

      final RecordedHttpRequest mint = http.requests.single;
      expect(mint.url, kSpotifyAccountsTokenEndpoint);
      expect(mint.method, 'POST');
      expect(mint.body, 'grant_type=client_credentials');
      expect(
        mint.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('client-id:client-secret'))}',
      );
      // The session cookie has no business here.
      expect(mint.headers['cookie'], isNull);
    });

    test('a rejected application credential is an auth failure', () async {
      http.enqueueJson(<String, Object?>{}, statusCode: 401);
      await expectLater(
        appTokens.token(),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
    });

    test('reuses a live token rather than minting per lookup', () async {
      _enqueueAppToken(http);
      expect(await appTokens.token(), 'app-token');
      expect(await appTokens.token(), 'app-token');
      expect(http.requests, hasLength(1));
    });
  });

  group('SpotifyTokenSource', () {
    test('is unconfigured until a cookie is provided', () {
      expect(webSource(null).isConfigured, isFalse);
      expect(webSource('   ').isConfigured, isFalse);
      expect(webSource('sp').isConfigured, isTrue);
    });

    test('an anonymous session is refused, not accepted', () async {
      // The endpoint answers a bad cookie with 200 and a perfectly valid
      // anonymous token. An anonymous session can see no canvases, so taking
      // it produced a confident "no canvas for this song" for what was really
      // "you are not signed in". Verified against the live endpoint: called
      // with no cookie at all it returns exactly this.
      http
        ..enqueueJson(<String, Object?>{'serverTime': 1767000000})
        ..enqueueJson(<String, Object?>{
          'accessToken': 'anonymous-token',
          'isAnonymous': true,
        });
      await expectLater(
        tokens.token(),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
    });

    test('names the TOTP version it computed the code under', () async {
      _enqueueWebToken(http);
      await tokens.token();

      final RecordedHttpRequest mint = http.requests[1];
      expect(mint.url.path, '/api/token');
      expect(mint.url.queryParameters['totpVer'], '$kSpotifyTotpVersion');
      expect(mint.url.queryParameters['totp'], hasLength(kTotpDigits));
      // Both carry the server-derived code, so a skewed clock still mints.
      expect(
        mint.url.queryParameters['totp'],
        mint.url.queryParameters['totpServer'],
      );
    });

    test('a settings override replaces the embedded version', () {
      expect(
        SpotifyTokenSource(
          http: http,
          spDc: () => 'cookie',
          totpVersion: () => '77',
        ).totpVersion,
        77,
      );
    });

    test('an empty or nonsense override falls back to the embedded one', () {
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

    test('a rejected cookie is an auth failure', () async {
      http
        ..enqueueJson(<String, Object?>{'serverTime': 1767000000})
        ..enqueueJson(<String, Object?>{}, statusCode: 401);
      await expectLater(
        tokens.token(),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
    });

    test('an unreachable clock falls back to the local one', () async {
      http
        ..enqueueError()
        ..enqueueJson(<String, Object?>{
          'accessToken': 'web-token',
          'isAnonymous': false,
        });
      expect(await tokens.token(), 'web-token');
    });
  });

  group('SpotifyCanvasClient', () {
    test('searches with the application credential, not the cookie', () async {
      // The whole reason there are two credentials. A web-player token is
      // answered 429 by api.spotify.com on the first request and every one
      // after it, verified against the live service.
      _enqueueAppToken(http);
      http.enqueueJson(_searchBody(<Object>[_searchHit()]));
      _enqueueWebToken(http);
      http.enqueueResponse(
        SwayveHttpResponse(statusCode: 200, bodyBytes: _canvasResponse()),
      );

      await client.canvas(_track());

      final RecordedHttpRequest search = http.requests[1];
      expect(search.url.host, 'api.spotify.com');
      expect(search.headers['authorization'], 'Bearer app-token');
      expect(search.headers['cookie'], isNull);
      expect(search.url.queryParameters['q'], contains('track:'));
      expect(search.url.queryParameters['q'], contains('artist:'));
    });

    test('fetches the canvas with the session token', () async {
      _enqueueAppToken(http);
      http.enqueueJson(
        _searchBody(<Object>[_searchHit(uri: 'spotify:track:xyz')]),
      );
      _enqueueWebToken(http);
      http.enqueueResponse(
        SwayveHttpResponse(
          statusCode: 200,
          bodyBytes: _canvasResponse(trackUri: 'spotify:track:xyz'),
        ),
      );

      await client.canvas(_track());

      final RecordedHttpRequest canvas = http.requests.last;
      expect(canvas.method, 'POST');
      expect(canvas.url, kSpotifyCanvasEndpoint);
      expect(canvas.headers['authorization'], 'Bearer web-token');
      expect(canvas.headers['accept'], 'application/protobuf');
      expect(
        utf8.decode(canvas.body! as List<int>, allowMalformed: true),
        contains('spotify:track:xyz'),
      );
    });

    test('returns the canvas as portrait motion artwork', () async {
      _enqueueAppToken(http);
      http.enqueueJson(_searchBody(<Object>[_searchHit()]));
      _enqueueWebToken(http);
      http.enqueueResponse(
        SwayveHttpResponse(statusCode: 200, bodyBytes: _canvasResponse()),
      );

      final SwayveVisual? visual = await client.canvas(_track());
      expect(visual, isNotNull);
      expect(visual!.kind, SwayveVisualKind.motionArtwork);
      expect(visual.uri.host, 'canvaz.scdn.co');
      expect(visual.source, 'Spotify');
      expect(visual.loops, isTrue);
      expect(visual.aspectRatio, closeTo(9 / 16, 0.001));
    });

    test('never mints a session token for an unfindable recording', () async {
      // The cookie is the more sensitive credential; there is no reason to
      // touch it for a song that could not be looked up.
      _enqueueAppToken(http);
      http.enqueueJson(_searchBody(const <Object>[]));

      expect(await client.canvas(_track()), isNull);
      expect(http.requests, hasLength(2));
      for (final RecordedHttpRequest request in http.requests) {
        expect(request.headers['cookie'], isNull);
      }
    });

    test('429 on search says the credential is the likely cause', () async {
      // What a web-player token gets here, always. Reported as its own thing
      // so it can never read as "this song has no canvas".
      _enqueueAppToken(http);
      http.enqueueResponse(
        const SwayveHttpResponse(
          statusCode: 429,
          headers: <String, String>{'retry-after': '30'},
        ),
      );
      await expectLater(
        client.canvas(_track()),
        throwsA(
          isA<SwayvePluginRateLimitedException>().having(
            (e) => e.message,
            'message',
            contains('registered application credential'),
          ),
        ),
      );
    });

    test('declines a hit whose title disagrees', () async {
      _enqueueAppToken(http);
      http.enqueueJson(
        _searchBody(<Object>[_searchHit(name: 'Something Else Entirely')]),
      );
      expect(await client.canvas(_track()), isNull);
    });

    test('declines a hit whose artist disagrees', () async {
      _enqueueAppToken(http);
      http.enqueueJson(
        _searchBody(<Object>[_searchHit(artist: 'Someone Else')]),
      );
      expect(await client.canvas(_track()), isNull);
    });

    test('declines a hit whose running time is far out', () async {
      _enqueueAppToken(http);
      http.enqueueJson(_searchBody(<Object>[_searchHit(durationMs: 400000)]));
      expect(await client.canvas(_track()), isNull);
    });

    test('prefers the closest running time over search rank', () async {
      _enqueueAppToken(http);
      http.enqueueJson(
        _searchBody(<Object>[
          _searchHit(durationMs: 200000, uri: 'spotify:track:radio'),
          _searchHit(durationMs: 216000, uri: 'spotify:track:album'),
        ]),
      );
      _enqueueWebToken(http);
      http.enqueueResponse(
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

    test('404 from the canvas endpoint means no canvas', () async {
      _enqueueAppToken(http);
      http.enqueueJson(_searchBody(<Object>[_searchHit()]));
      _enqueueWebToken(http);
      http.enqueueResponse(const SwayveHttpResponse(statusCode: 404));
      expect(await client.canvas(_track()), isNull);
    });

    test('a canvas naming a different track is not accepted', () async {
      _enqueueAppToken(http);
      http.enqueueJson(_searchBody(<Object>[_searchHit()]));
      _enqueueWebToken(http);
      http.enqueueResponse(
        SwayveHttpResponse(
          statusCode: 200,
          bodyBytes: _canvasResponse(trackUri: 'spotify:track:someone-else'),
        ),
      );
      expect(await client.canvas(_track()), isNull);
    });

    test('refuses media from a host outside the allowlist', () async {
      _enqueueAppToken(http);
      http.enqueueJson(_searchBody(<Object>[_searchHit()]));
      _enqueueWebToken(http);
      http.enqueueResponse(
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
  });

  group('SpotifyCanvasVisualsSource', () {
    SpotifyCanvasVisualsSource sourceWith({
      String? spDc = 'cookie-value',
      String? id = 'client-id',
      String? secret = 'client-secret',
    }) {
      final web = webSource(spDc);
      final app = appSource(id, secret);
      return SpotifyCanvasVisualsSource(
        client: SpotifyCanvasClient(http: http, tokens: web, appTokens: app),
        tokens: web,
        appTokens: app,
      );
    }

    test('stands aside silently when no cookie was provided', () async {
      expect(await sourceWith(spDc: null).visual(_track()), isNull);
      // An add-on nobody switched on costs nothing.
      expect(http.requests, isEmpty);
    });

    test('says so when the cookie is set but the application is not', () async {
      // Half configured is somebody who tried. Silence here would leave no
      // explanation anywhere for a background that never moves.
      await expectLater(
        sourceWith(id: null, secret: null).visual(_track()),
        throwsA(
          isA<SwayvePluginAuthRequiredException>().having(
            (e) => e.message,
            'message',
            contains('application client id and secret'),
          ),
        ),
      );
      expect(http.requests, isEmpty);
    });

    test('an expired cookie propagates rather than answering null', () async {
      // It must not look like "this song has no canvas": the host caches a
      // negative answer for ten minutes and deliberately does not cache one
      // when a provider threw, so that correcting the setting takes effect
      // without restarting the app.
      _enqueueAppToken(http);
      http.enqueueJson(_searchBody(<Object>[_searchHit()]));
      http
        ..enqueueJson(<String, Object?>{'serverTime': 1767000000})
        ..enqueueJson(<String, Object?>{}, statusCode: 401);

      await expectLater(
        sourceWith().visual(_track()),
        throwsA(isA<SwayvePluginAuthRequiredException>()),
      );
    });

    test('the provider still falls through to a later source', () async {
      _enqueueAppToken(http);
      http.enqueueJson(_searchBody(<Object>[_searchHit()]));
      http
        ..enqueueJson(<String, Object?>{'serverTime': 1767000000})
        ..enqueueJson(<String, Object?>{}, statusCode: 401);

      final provider = SourceAgnosticVisualsProvider(<VisualsSource>[
        sourceWith(),
        _StubSource(
          SwayveVisual(
            uri: Uri.parse(
              'https://resources.tidal.com/videos/x/1280x1280.mp4',
            ),
            kind: SwayveVisualKind.motionArtwork,
            source: 'TIDAL',
          ),
        ),
      ]);
      expect((await provider.visual(_track()))?.source, 'TIDAL');
    });

    test('returns the canvas when everything is configured', () async {
      _enqueueAppToken(http);
      http.enqueueJson(_searchBody(<Object>[_searchHit()]));
      _enqueueWebToken(http);
      http.enqueueResponse(
        SwayveHttpResponse(statusCode: 200, bodyBytes: _canvasResponse()),
      );
      expect((await sourceWith().visual(_track()))?.source, 'Spotify');
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
