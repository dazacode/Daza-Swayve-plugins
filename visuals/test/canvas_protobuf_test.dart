import 'dart:convert';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';
import 'package:visuals/visuals.dart';

/// Bytes for a `CanvasResponse` holding the given canvases.
///
/// Written by hand rather than by the encoder under test: a round-trip
/// through one implementation proves only that it is self-consistent, which
/// is exactly the failure a hand-rolled codec is prone to.
List<int> _response(
  List<({String url, String trackUri})> canvases, {
  bool withNoise = false,
}) {
  final List<int> out = <int>[];
  for (final canvas in canvases) {
    final List<int> body = <int>[
      if (withNoise) ...<int>[0x08, 0x2a], // field 1, varint — skipped
      0x12, ..._delimited(canvas.url), // field 2, canvas_url
      if (withNoise) ...<int>[
        0x32, ..._delimited('spotify:artist:x'), // field 6, artist — skipped
      ],
      0x2a, ..._delimited(canvas.trackUri), // field 5, track_uri
    ];
    out
      ..add(0x0a) // field 1, length-delimited
      ..addAll(_varint(body.length))
      ..addAll(body);
  }
  return out;
}

List<int> _delimited(String value) {
  final List<int> bytes = utf8.encode(value);
  return <int>[...(_varint(bytes.length)), ...bytes];
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

void main() {
  group('encodeCanvasRequest', () {
    test('wraps one track uri in the nested Track message', () {
      // CanvasRequest.tracks[0].track_uri = "spotify:track:abc"
      //   0x0a <len> ( 0x0a <len> "spotify:track:abc" )
      final bytes = encodeCanvasRequest(<String>['spotify:track:abc']);
      expect(bytes[0], 0x0a);
      expect(bytes[1], 19); // inner tag + inner length + 17 bytes of uri
      expect(bytes[2], 0x0a);
      expect(bytes[3], 17);
      expect(utf8.decode(bytes.sublist(4)), 'spotify:track:abc');
    });

    test('encodes several tracks as repeated fields', () {
      final bytes = encodeCanvasRequest(<String>['a', 'bb']);
      // Two top-level entries, each tagged 0x0a.
      expect(bytes.where((int b) => b == 0x0a).length, greaterThanOrEqualTo(2));
      expect(utf8.decode(bytes).contains('a'), isTrue);
      expect(utf8.decode(bytes).contains('bb'), isTrue);
    });

    test('an empty list encodes to an empty message', () {
      expect(encodeCanvasRequest(const <String>[]), isEmpty);
    });
  });

  group('decodeCanvasResponse', () {
    test('reads the url and track uri out of one canvas', () {
      final entries = decodeCanvasResponse(
        _response([
          (
            url: 'https://canvaz.scdn.co/upload/a/video/b.cnvs.mp4',
            trackUri: 'spotify:track:abc'
          ),
        ]),
      );
      expect(entries, hasLength(1));
      expect(
        entries.single.canvasUrl,
        'https://canvaz.scdn.co/upload/a/video/b.cnvs.mp4',
      );
      expect(entries.single.trackUri, 'spotify:track:abc');
    });

    test('skips fields it does not read', () {
      // The artist block and the opaque ids are present on every real
      // response and must not derail the parse.
      final entries = decodeCanvasResponse(
        _response(
          [
            (
              url: 'https://canvaz.scdn.co/x.mp4',
              trackUri: 'spotify:track:abc'
            ),
          ],
          withNoise: true,
        ),
      );
      expect(entries, hasLength(1));
      expect(entries.single.canvasUrl, 'https://canvaz.scdn.co/x.mp4');
      expect(entries.single.trackUri, 'spotify:track:abc');
    });

    test('reads several canvases', () {
      final entries = decodeCanvasResponse(
        _response([
          (url: 'https://canvaz.scdn.co/one.mp4', trackUri: 'spotify:track:1'),
          (url: 'https://canvaz.scdn.co/two.mp4', trackUri: 'spotify:track:2'),
        ]),
      );
      expect(
        entries.map((e) => e.trackUri),
        <String>['spotify:track:1', 'spotify:track:2'],
      );
    });

    test('an empty message means no canvas, not a failure', () {
      // The ordinary answer for most recordings.
      expect(decodeCanvasResponse(const <int>[]), isEmpty);
    });

    test('a canvas with no url is dropped rather than returned empty', () {
      final bytes = <int>[
        0x0a, ..._delimited(''), // one canvas, no fields at all
      ];
      expect(decodeCanvasResponse(bytes), isEmpty);
    });

    test('an HTML error page is a malformed response, not silence', () {
      // The distinction that matters: "no canvas" and "the endpoint answered
      // with something that is not a canvas response" get different handling
      // upstream, so they must not decode to the same empty list.
      expect(
        () => decodeCanvasResponse(utf8.encode('<html>Bad Gateway</html>')),
        throwsA(isA<SwayvePluginMalformedResponseException>()),
      );
    });

    test('a truncated message throws rather than returning half an answer', () {
      final full = _response([
        (url: 'https://canvaz.scdn.co/x.mp4', trackUri: 'spotify:track:abc'),
      ]);
      expect(
        () => decodeCanvasResponse(full.sublist(0, full.length - 4)),
        throwsA(isA<SwayvePluginMalformedResponseException>()),
      );
    });

    test('a length running past the end of the buffer throws', () {
      expect(
        () => decodeCanvasResponse(<int>[0x0a, 0x7f, 0x01]),
        throwsA(isA<SwayvePluginMalformedResponseException>()),
      );
    });
  });
}
