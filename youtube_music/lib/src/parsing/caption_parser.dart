/// The parser for a YouTube caption track.
///
/// Captions are not lyrics, and this file is the whole of the difference. A
/// lyric is a published text; a caption track is a transcript somebody typed
/// or a machine heard, and for an official music upload it is very often the
/// lyric written out with timings on it. That makes it the best synced text
/// this plugin can honestly obtain — see `providers/lyrics_provider.dart` for
/// why YouTube Music's own lyrics browse is not an option — and it makes the
/// attribution ("YouTube captions") load-bearing rather than decorative.
///
/// Two wire formats arrive from the same endpoint and both are read:
///
/// * the default `<transcript><text start="1.36" dur="1.68">`, seconds as
///   decimals;
/// * `fmt=srv3`'s `<timedtext><body><p t="1360" d="1680">`, whole
///   milliseconds.
///
/// Written by hand rather than with an XML package: a plugin's `lib/` is pure
/// Dart with the SDK as its only dependency, and this is a flat list of
/// single-level elements — there is no nesting to get wrong.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// The `fmt` query parameter this plugin never wants on a caption URL.
///
/// A `baseUrl` handed over by the player response usually carries no `fmt` at
/// all, but the web app appends one and a URL copied from it would. Both
/// formats parse, so stripping it is belt and braces rather than a
/// requirement — see [captionUrl].
const String kCaptionFormatParameter = 'fmt';

/// [url] with any caption format parameter taken off.
///
/// Returns the default `<transcript>` rendering, which is the one the
/// `baseUrl` on a player response already points at.
Uri captionUrl(Uri url) {
  if (!url.queryParameters.containsKey(kCaptionFormatParameter)) return url;
  final Map<String, String> query = Map<String, String>.of(
    url.queryParameters,
  )..remove(kCaptionFormatParameter);
  return url.replace(queryParameters: query.isEmpty ? null : query);
}

final RegExp _transcriptCue = RegExp(
  r'<text\b([^>]*)>([\s\S]*?)</text>',
  caseSensitive: false,
);

final RegExp _srv3Cue = RegExp(
  r'<p\b([^>]*)>([\s\S]*?)</p>',
  caseSensitive: false,
);

final RegExp _attribute = RegExp(
  '([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*"([^"]*)"',
);

final RegExp _tag = RegExp('<[^>]*>');

final RegExp _namedEntity =
    RegExp(r'&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);');

/// The timed lines of a caption document, in ascending order.
///
/// Empty when the body is not a caption document or carries no cues — never
/// an exception. A caption track that came back as an error page is a lyric
/// this plugin does not have, which is the ordinary case rather than a
/// failure.
List<SwayveLyricLine> parseCaptionLines(String body) {
  final List<SwayveLyricLine> lines = <SwayveLyricLine>[];

  for (final RegExpMatch match in _transcriptCue.allMatches(body)) {
    final Map<String, String> attributes = _attributesOf(match.group(1) ?? '');
    final Duration? at = _seconds(attributes['start']);
    if (at == null) continue;
    lines.add(SwayveLyricLine(at: at, text: _text(match.group(2) ?? '')));
  }
  if (lines.isNotEmpty) return _ordered(lines);

  for (final RegExpMatch match in _srv3Cue.allMatches(body)) {
    final Map<String, String> attributes = _attributesOf(match.group(1) ?? '');
    final Duration? at = _milliseconds(attributes['t']);
    if (at == null) continue;
    lines.add(SwayveLyricLine(at: at, text: _text(match.group(2) ?? '')));
  }
  return _ordered(lines);
}

/// The same lines joined into one plain-text lyric, or `null` when there are
/// none.
///
/// Published alongside the synced form rather than instead of it: the SDK
/// asks a provider that has one to fill in the other, because the surfaces
/// that cannot scroll in time still want the words.
String? plainFromLines(List<SwayveLyricLine> lines) {
  if (lines.isEmpty) return null;
  final String text =
      lines.map((SwayveLyricLine line) => line.text).join('\n').trim();
  return text.isEmpty ? null : text;
}

List<SwayveLyricLine> _ordered(List<SwayveLyricLine> lines) {
  lines.sort((SwayveLyricLine a, SwayveLyricLine b) => a.at.compareTo(b.at));
  return List<SwayveLyricLine>.unmodifiable(lines);
}

Map<String, String> _attributesOf(String source) => <String, String>{
      for (final RegExpMatch match in _attribute.allMatches(source))
        match.group(1)!.toLowerCase(): match.group(2)!,
    };

/// A decimal count of seconds as a `Duration`, to the millisecond.
Duration? _seconds(String? value) {
  if (value == null) return null;
  final double? parsed = double.tryParse(value.trim());
  if (parsed == null || !parsed.isFinite || parsed < 0) return null;
  return Duration(milliseconds: (parsed * 1000).round());
}

Duration? _milliseconds(String? value) {
  if (value == null) return null;
  final int? parsed = int.tryParse(value.trim());
  if (parsed == null || parsed < 0) return null;
  return Duration(milliseconds: parsed);
}

/// One cue's body as the text a person would read.
///
/// Entities are decoded **twice**, and that is not paranoia. The default
/// `<transcript>` rendering escapes its content and then escapes the escapes:
/// an apostrophe arrives as `&amp;#39;`, so a single pass leaves `&#39;`
/// sitting in the middle of the line. A second pass is bounded and the loop
/// stops as soon as a pass changes nothing, so text that genuinely contains
/// `&amp;` survives as `&`.
String _text(String source) {
  String text = source.replaceAll(_tag, '');
  for (int pass = 0; pass < 2; pass++) {
    final String decoded = _decodeEntities(text);
    if (decoded == text) break;
    text = decoded;
  }
  // A cue is wrapped across lines in the payload for layout; the line break
  // is not part of the lyric.
  return text.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
}

String _decodeEntities(String source) =>
    source.replaceAllMapped(_namedEntity, (Match match) {
      final String entity = match.group(1)!;
      switch (entity) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
      }
      final int? code = entity.startsWith('#x') || entity.startsWith('#X')
          ? int.tryParse(entity.substring(2), radix: 16)
          : int.tryParse(entity.substring(1));
      if (code == null || code < 0 || code > 0x10FFFF) return match.group(0)!;
      return String.fromCharCode(code);
    });
