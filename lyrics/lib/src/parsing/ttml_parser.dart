/// The parser for the TTML document BetterLyrics answers with.
///
/// ## What actually comes back
///
/// The brief this plugin was written to expected BetterLyrics to answer with a
/// JSON array of words. It does not, and this file is shaped to what the live
/// service returned rather than to what was expected of it. `GET
/// https://lyrics-api.boidu.dev/getLyrics?s=…&a=…` answers with a JSON object
/// carrying **one string field**, `ttml`, whose value is an Apple Music
/// word-timed TTML document:
///
/// ```xml
/// <tt xmlns="http://www.w3.org/ns/ttml" itunes:timing="Word" xml:lang="en">
///   <head>…songwriters, agents, translations…</head>
///   <body dur="3:21.570">
///     <div begin="27.395" end="48.621" itunes:songPart="Verse">
///       <p begin="27.395" end="28.960" itunes:key="L1" ttm:agent="v1">
///         <span begin="27.395" end="27.549">I</span>
///         <span begin="27.549" end="27.740">been</span>
///       </p>
///     </div>
///   </body>
/// </tt>
/// ```
///
/// Three consequences follow from that, and each of them is a decision this
/// file makes rather than a fact it inherits.
///
/// **A `<p>` is a line and a `<span>` is a word.** That is the whole mapping
/// onto [SwayveLyrics]: `words` is the `<p>`s, each holding its `<span>`s, and
/// `synced` is the same `<p>`s reduced to their starts. Unlike enhanced LRC —
/// see `lrc_parser.dart`, which has to invent an end for the last word of every
/// line — every span here carries a real `end`, so nothing is inferred.
///
/// **Spans nest, so this cannot be a flat regular expression.** A background
/// vocal arrives as `<span ttm:role="x-bg">` wrapping its own word spans, and a
/// non-greedy `<span…>(.*?)</span>` would pair the outer open tag with the
/// inner close tag and produce nonsense. So the scan below tracks depth.
///
/// **Background vocals are dropped.** Their timings deliberately overlap the
/// lead line they answer — `know` and `(Back to let you know)` are sung across
/// each other — and [SwayveLyrics.words] is one ordered list of words per line,
/// which cannot represent two things being sung at once. Interleaving them
/// would produce a line whose word timings run backwards. The lead vocal is the
/// lyric, so the lead vocal is what this keeps, and the loss is named here
/// rather than hidden.
///
/// Written by hand rather than with an XML package for the same reason every
/// other parser in this repository is: a plugin's `lib/` is pure Dart with the
/// SDK as its only dependency.
///
/// **Nothing in this file throws.** A document that is not TTML, or is TTML
/// with nothing timed in it, parses to [ParsedTtml.empty].
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// The parsed form of one TTML document.
final class ParsedTtml {
  /// Creates a parse result.
  const ParsedTtml({
    required this.lines,
    required this.words,
    required this.duration,
  });

  /// A document with nothing in it.
  static const ParsedTtml empty = ParsedTtml(
    lines: <SwayveLyricLine>[],
    words: null,
    duration: null,
  );

  /// The lines, in ascending order.
  final List<SwayveLyricLine> lines;

  /// Word timing, when the document carried any.
  ///
  /// `null` for a document timed at the line level only — `itunes:timing`
  /// distinguishes `Word` from `Line`, and the SDK asks a provider not to
  /// claim word timing it does not have.
  final List<List<SwayveLyricWord>>? words;

  /// What `<body dur="…">` says the recording runs for, when it says anything.
  ///
  /// The one fact in the document that can be checked against the track this
  /// plugin was asked about. BetterLyrics does its own matching and does not
  /// echo back the title or the credit it matched, so this is the whole of the
  /// independent verification available — see `sources/betterlyrics_source.dart`
  /// for what is done with it.
  final Duration? duration;

  /// Whether anything at all was parsed.
  bool get isEmpty => lines.isEmpty;
}

final RegExp _bodyElement = RegExp(
  r'<body\b([^>]*)>([\s\S]*)</body\s*>',
  caseSensitive: false,
);

final RegExp _lineElement = RegExp(
  r'<p\b([^>]*)>([\s\S]*?)</p\s*>',
  caseSensitive: false,
);

/// Any tag: an open tag, a close tag or a self-closing one. The scan in
/// [_wordsOf] walks these in order and keeps its own depth count.
final RegExp _anyTag = RegExp(r'<(/?)([a-zA-Z][-a-zA-Z0-9:]*)\b([^>]*?)(/?)>');

final RegExp _attribute = RegExp(
  '([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*"([^"]*)"',
);

final RegExp _tag = RegExp('<[^>]*>');

final RegExp _namedEntity =
    RegExp(r'&(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);');

final RegExp _whitespace = RegExp(r'\s+');

/// Parses a TTML document.
ParsedTtml parseTtml(String document) {
  final RegExpMatch? body = _bodyElement.firstMatch(document);
  if (body == null) return ParsedTtml.empty;

  final Duration? duration = parseTtmlTime(
    _attributesOf(body.group(1) ?? '')['dur'],
  );

  final List<SwayveLyricLine> lines = <SwayveLyricLine>[];
  final List<List<SwayveLyricWord>> words = <List<SwayveLyricWord>>[];

  for (final RegExpMatch line in _lineElement.allMatches(body.group(2)!)) {
    final Map<String, String> attributes = _attributesOf(line.group(1) ?? '');
    final String inner = line.group(2) ?? '';

    final _LeadVocal lead = _leadVocalOf(inner);
    // The line's own `begin` when it has one, and the first word's start when
    // it does not. Preferring the attribute matters: a `<p>` whose only timed
    // content was a background vocal has no word left to take a start from.
    final Duration? at =
        parseTtmlTime(attributes['begin']) ?? lead.words.firstOrNull?.at;
    if (at == null) continue;

    lines.add(SwayveLyricLine(at: at, text: lead.text));
    if (lead.words.isNotEmpty) words.add(lead.words);
  }

  if (lines.isEmpty) return ParsedTtml.empty;

  return ParsedTtml(
    lines: List<SwayveLyricLine>.unmodifiable(lines),
    // Only claimed when *every* line carried words. A document where half the
    // lines are word-timed and half are not would otherwise hand the host a
    // `words` list that silently does not line up with `synced`, and the SDK is
    // explicit that nothing requires the two to have the same length — which
    // means a host is entitled to read them independently and would draw the
    // wrong line's karaoke.
    words: words.length == lines.length
        ? List<List<SwayveLyricWord>>.unmodifiable(words)
        : null,
    duration: duration,
  );
}

/// One `<p>` with its background vocals taken out.
final class _LeadVocal {
  const _LeadVocal({required this.text, required this.words});

  /// The line as a reader would see it.
  final String text;

  /// The line's timed words.
  final List<SwayveLyricWord> words;
}

/// The lead vocal of one `<p>`: its text and its timed words, both with the
/// background-vocal subtrees removed.
///
/// The scan is depth-aware because it has to be: `<span ttm:role="x-bg">` wraps
/// further spans, and the whole subtree under one has to be skipped rather than
/// descended into. A non-greedy flat regular expression would pair the outer
/// open tag with the inner close tag and produce a word whose text is the whole
/// background phrase.
///
/// The text is taken from the surviving markup rather than assembled from the
/// words, and that is load-bearing. Apple's documents split a word across
/// syllables — `<span>e</span><span>nough</span>` with no whitespace between
/// them — so joining the word texts with spaces would write "e nough". The
/// original spacing is the only thing that knows where the real word boundaries
/// were.
_LeadVocal _leadVocalOf(String inner) {
  final List<SwayveLyricWord> words = <SwayveLyricWord>[];
  // Half-open ranges of `inner` covering a whole background-vocal element,
  // open tag through close tag, collected so the text can be built without
  // them.
  final List<(int, int)> background = <(int, int)>[];

  // Each entry is one open `<span>` still on the stack.
  final List<_OpenSpan> stack = <_OpenSpan>[];

  for (final RegExpMatch tag in _anyTag.allMatches(inner)) {
    if (tag.group(2)!.toLowerCase() != 'span') continue;
    final bool closing = tag.group(1) == '/';
    final bool selfClosing = tag.group(4) == '/';

    if (closing) {
      if (stack.isEmpty) continue;
      final _OpenSpan open = stack.removeLast();
      if (open.background) {
        // Only the outermost one is recorded: the ranges are removed from the
        // text below, and a nested pair would be removed twice.
        if (!stack.any((_OpenSpan entry) => entry.background)) {
          background.add((open.tagStart, tag.end));
        }
        continue;
      }
      if (stack.any((_OpenSpan entry) => entry.background)) continue;
      final Duration? at = parseTtmlTime(open.attributes['begin']);
      final Duration? until = parseTtmlTime(open.attributes['end']);
      if (at == null || until == null) continue;
      final String text =
          _textOf(inner.substring(open.contentStart, tag.start));
      // The SDK says a word's text is never empty and its end is never before
      // its start. Both are enforced here rather than trusted, because the
      // document is somebody else's.
      if (text.isEmpty) continue;
      words.add(
        SwayveLyricWord(at: at, until: until < at ? at : until, text: text),
      );
      continue;
    }

    if (selfClosing) continue;
    final Map<String, String> attributes = _attributesOf(tag.group(3) ?? '');
    stack.add(
      _OpenSpan(
        tagStart: tag.start,
        contentStart: tag.end,
        attributes: attributes,
        background: attributes['ttm:role'] == 'x-bg',
      ),
    );
  }

  // A `<p>`'s spans are written in the order they are sung, but sorting is
  // cheap and makes the ascending order the SDK asks for true rather than
  // assumed.
  words.sort((SwayveLyricWord a, SwayveLyricWord b) => a.at.compareTo(b.at));

  final StringBuffer lead = StringBuffer();
  var cursor = 0;
  for (final (int from, int to) in background) {
    if (from < cursor) continue;
    lead.write(inner.substring(cursor, from));
    cursor = to;
  }
  lead.write(inner.substring(cursor));

  return _LeadVocal(
    text: _textOf(lead.toString()),
    words: List<SwayveLyricWord>.unmodifiable(words),
  );
}

final class _OpenSpan {
  const _OpenSpan({
    required this.tagStart,
    required this.contentStart,
    required this.attributes,
    required this.background,
  });

  /// Where the `<span…>` open tag starts in the enclosing fragment.
  final int tagStart;

  /// Where the span's content starts, just past the open tag.
  final int contentStart;

  final Map<String, String> attributes;

  /// Whether this span is `ttm:role="x-bg"`.
  final bool background;
}

/// The readable text of a fragment: tags stripped, entities decoded,
/// whitespace collapsed.
String _textOf(String fragment) =>
    _decodeEntities(fragment.replaceAll(_tag, ''))
        .replaceAll(_whitespace, ' ')
        .trim();

Map<String, String> _attributesOf(String source) => <String, String>{
      for (final RegExpMatch match in _attribute.allMatches(source))
        match.group(1)!.toLowerCase(): match.group(2)!,
    };

/// Parses a TTML clock or offset value.
///
/// Every form the observed documents use, and they use three of them in the
/// same file: `27.395` (seconds), `1:00.964` (minutes and seconds) and
/// `3:21.570` on `<body dur>`. The `hh:mm:ss.mmm` form is accepted too because
/// it is the format's own canonical one and a longer recording will produce it.
///
/// `null` for anything else, including the frame- and tick-based forms TTML
/// also permits (`00:00:01:12`, `120t`). Those need a frame rate this document
/// does not carry, and a guessed one would put every word in the wrong place.
Duration? parseTtmlTime(String? value) {
  if (value == null) return null;
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return null;

  final List<String> parts = trimmed.split(':');
  if (parts.length > 3) return null;

  // The last part carries the seconds and any fraction; everything before it
  // is a whole number of minutes, then of hours.
  final double? seconds = double.tryParse(parts.last);
  if (seconds == null || !seconds.isFinite || seconds < 0) return null;

  var total = (seconds * 1000).round();
  const List<int> scales = <int>[60000, 3600000];
  for (var i = 0; i < parts.length - 1; i++) {
    final int? unit = int.tryParse(parts[parts.length - 2 - i]);
    if (unit == null || unit < 0) return null;
    total += unit * scales[i];
  }
  return Duration(milliseconds: total);
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
