/// The two protobuf messages Spotify's canvas endpoint speaks.
///
/// Hand-rolled for the same reason `hmac_sha1.dart` is: `package:protobuf`
/// plus a generator step is a large amount of machinery, and a second
/// dependency, for two messages with six scalar fields between them. The
/// wire format is a published standard and the parts of it these messages use
/// are the two simplest — varints and length-delimited bytes.
///
/// The schema, as the endpoint defines it:
///
/// ```proto
/// message CanvasRequest {
///   message Track { string track_uri = 1; }
///   repeated Track tracks = 1;
/// }
///
/// message CanvasResponse {
///   message Canvas {
///     string id = 1;
///     string canvas_url = 2;
///     string track_uri = 5;
///     Artist artist = 6;
///     string other_id = 9;
///     string canvas_uri = 11;
///   }
///   repeated Canvas canvases = 1;
/// }
/// ```
///
/// Only `canvas_url` and `track_uri` are read back. The artist block and the
/// two opaque ids are skipped, not parsed: this plugin already knows which
/// artist it asked about, and a decoder that reads fields nobody uses is a
/// decoder with more ways to break when the schema grows.
library;

import 'dart:convert';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// One canvas, as far as this plugin cares about one.
class CanvasEntry {
  /// Creates an entry.
  const CanvasEntry({required this.canvasUrl, required this.trackUri});

  /// Where the looping video lives — a `canvaz.scdn.co` MP4.
  final String canvasUrl;

  /// The `spotify:track:…` URI this canvas belongs to.
  final String trackUri;

  @override
  String toString() => 'CanvasEntry($trackUri, $canvasUrl)';
}

/// Encodes a `CanvasRequest` asking about [trackUris].
List<int> encodeCanvasRequest(Iterable<String> trackUris) {
  final List<int> out = <int>[];
  for (final String uri in trackUris) {
    // Track { string track_uri = 1; }
    final List<int> track = <int>[
      ..._tag(1, _wireLengthDelimited),
      ..._lengthDelimited(utf8.encode(uri)),
    ];
    // CanvasRequest { repeated Track tracks = 1; }
    out
      ..addAll(_tag(1, _wireLengthDelimited))
      ..addAll(_lengthDelimited(track));
  }
  return out;
}

/// Decodes a `CanvasResponse`, returning every canvas it names.
///
/// Throws `SwayvePluginMalformedResponseException` when the bytes are not a
/// protobuf message at all — which is what arrives when the endpoint answers
/// with an HTML error page, and is worth telling apart from "this track has
/// no canvas", which is a perfectly ordinary empty message.
List<CanvasEntry> decodeCanvasResponse(List<int> bytes) {
  final List<CanvasEntry> canvases = <CanvasEntry>[];
  final _Reader reader = _Reader(bytes);

  while (!reader.isAtEnd) {
    final _Field field = reader.readField();
    if (field.number == 1 && field.wireType == _wireLengthDelimited) {
      final CanvasEntry? entry = _decodeCanvas(reader.readLengthDelimited());
      if (entry != null) canvases.add(entry);
    } else {
      reader.skip(field.wireType);
    }
  }
  return canvases;
}

CanvasEntry? _decodeCanvas(List<int> bytes) {
  String? canvasUrl;
  String? trackUri;

  final _Reader reader = _Reader(bytes);
  while (!reader.isAtEnd) {
    final _Field field = reader.readField();
    if (field.wireType == _wireLengthDelimited && field.number == 2) {
      canvasUrl =
          utf8.decode(reader.readLengthDelimited(), allowMalformed: true);
    } else if (field.wireType == _wireLengthDelimited && field.number == 5) {
      trackUri =
          utf8.decode(reader.readLengthDelimited(), allowMalformed: true);
    } else {
      reader.skip(field.wireType);
    }
  }

  // A canvas with no URL is not a canvas. The track URI may legitimately be
  // absent when only one was asked about, so it falls back to empty and the
  // caller decides whether it needed the confirmation.
  if (canvasUrl == null || canvasUrl.trim().isEmpty) return null;
  return CanvasEntry(canvasUrl: canvasUrl.trim(), trackUri: trackUri ?? '');
}

const int _wireVarint = 0;
const int _wireFixed64 = 1;
const int _wireLengthDelimited = 2;
const int _wireFixed32 = 5;

List<int> _tag(int fieldNumber, int wireType) =>
    _varint((fieldNumber << 3) | wireType);

List<int> _lengthDelimited(List<int> payload) => <int>[
      ..._varint(payload.length),
      ...payload,
    ];

List<int> _varint(int value) {
  final List<int> out = <int>[];
  int remaining = value;
  while (remaining >= 0x80) {
    out.add((remaining & 0x7F) | 0x80);
    remaining >>= 7;
  }
  out.add(remaining);
  return out;
}

class _Field {
  const _Field(this.number, this.wireType);
  final int number;
  final int wireType;
}

class _Reader {
  _Reader(this._bytes);

  final List<int> _bytes;
  int _offset = 0;

  bool get isAtEnd => _offset >= _bytes.length;

  _Field readField() {
    final int key = _readVarint();
    final int number = key >> 3;
    if (number == 0) {
      throw SwayvePluginMalformedResponseException(
        'The canvas endpoint returned a protobuf field numbered zero, which '
        'no valid message contains.',
      );
    }
    return _Field(number, key & 0x07);
  }

  List<int> readLengthDelimited() {
    final int length = _readVarint();
    if (length < 0 || _offset + length > _bytes.length) {
      throw SwayvePluginMalformedResponseException(
        'The canvas endpoint returned a length-delimited field running past '
        'the end of the message.',
      );
    }
    final List<int> slice = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return slice;
  }

  void skip(int wireType) {
    switch (wireType) {
      case _wireVarint:
        _readVarint();
      case _wireFixed64:
        _advance(8);
      case _wireLengthDelimited:
        readLengthDelimited();
      case _wireFixed32:
        _advance(4);
      default:
        throw SwayvePluginMalformedResponseException(
          'The canvas endpoint returned protobuf wire type $wireType, which '
          'is not one this decoder can skip past.',
        );
    }
  }

  void _advance(int count) {
    if (_offset + count > _bytes.length) {
      throw SwayvePluginMalformedResponseException(
        'The canvas endpoint returned a fixed-width field running past the '
        'end of the message.',
      );
    }
    _offset += count;
  }

  int _readVarint() {
    int result = 0;
    int shift = 0;
    while (true) {
      if (isAtEnd) {
        throw SwayvePluginMalformedResponseException(
          'The canvas endpoint returned a varint running past the end of the '
          'message.',
        );
      }
      final int byte = _bytes[_offset++];
      result |= (byte & 0x7F) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift > 63) {
        throw SwayvePluginMalformedResponseException(
          'The canvas endpoint returned a varint wider than 64 bits.',
        );
      }
    }
  }
}
