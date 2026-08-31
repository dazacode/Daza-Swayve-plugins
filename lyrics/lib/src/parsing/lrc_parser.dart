/// The parser for LRC, the format LRCLIB publishes synced lyrics in.
///
/// LRC is a text file where every line is prefixed with one or more
/// timestamps:
///
/// ```text
/// [ar:The Weeknd]
/// [00:13.13] Yeah
/// [00:16.56] ♪
/// [00:27.16] I've been tryna call
/// [01:02.44][02:31.10] I said, ooh, I'm blinded by the lights
/// ```
///
/// Enhanced LRC adds word timings inside the line, in angle brackets:
///
/// ```text
/// [00:27.16] <00:27.16> I've <00:27.55> been <00:27.74> tryna <00:28.08> call
/// ```
///
/// Written by hand rather than with a package, for the same reason every other
/// parser in this repository is: a plugin's `lib/` is pure Dart with the SDK as
/// its only dependency, because a dependency that brings its own transport —
/// and most parsing packages that are worth having eventually do — cannot be
/// used inside a permission model built on a host-supplied transport.
///
/// **Nothing in this file throws.** A malformed timestamp costs its own line
/// and nothing else; a body that is not LRC at all parses to an empty list. A
/// lyric that failed to parse is a lyric this plugin does not have, and that is
/// the ordinary case rather than a failure — see `sources/lyrics_source.dart`.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// How long the last word of a line stays lit when nothing says otherwise.
///
/// Enhanced LRC gives every word a start and no word an end, so an end has to
/// come from somewhere. Within a line it comes from the next word, which is
/// exact: consecutive sung words abut. The *last* word of a line has no next
/// word, and the honest options are all bad — the SDK says as much, and warns
/// that inferring an end from the following line would keep the last word of
/// every phrase lit through the instrumental after it.
///
/// So the last word gets a fixed hold, and the following line's start caps it
/// when that comes sooner. Two seconds is long enough for a held note and short
/// enough that a word does not sit lit through a guitar solo. It is a
/// compromise and it is confined to one constant so that it is visible as one.
const Duration kFinalWordHold = Duration(seconds: 2);

/// A `[mm:ss.xx]` or `[mm:ss:xx]` line timestamp.
///
/// The fraction is optional and may be two digits (centiseconds, which is what
/// LRCLIB writes) or three (milliseconds, which some other producers write).
/// The separator before it is `.` in every modern file and `:` in some older
/// ones, and both are accepted because accepting the second costs one
/// character.
///
/// The minutes group is `\d{1,3}` rather than `\d{2}`: a track past 99 minutes
/// is rare and is not a reason to drop the line.
final RegExp _lineStamp = RegExp(r'\[(\d{1,3}):([0-5]?\d)(?:[.:](\d{1,3}))?\]');

/// A `<mm:ss.xx>` word timestamp, the enhanced-LRC extension.
final RegExp _wordStamp = RegExp(r'<(\d{1,3}):([0-5]?\d)(?:[.:](\d{1,3}))?>');

final RegExp _spacing = RegExp(r'\s+');

/// One line of an LRC document, before it is split into the SDK's two views.
///
/// Held as an intermediate because [parseLrc] has to produce both
/// [SwayveLyrics.synced] and [SwayveLyrics.words] from one pass, and because
/// the word timings of a line cannot be finished until the *next* line's start
/// is known.
final class LrcLine {
  /// Creates a parsed line.
  const LrcLine({required this.at, required this.text, required this.words});

  /// When the line begins, measured from the start of the track.
  final Duration at;

  /// The line's text, with any word timestamps taken out. Empty for the blank
  /// lines LRC uses to mark an instrumental gap.
  final String text;

  /// The line's word timings, each with a start and no end yet.
  ///
  /// Empty for a line with no enhanced-LRC markup, which is almost every line
  /// of almost every file.
  final List<(Duration, String)> words;
}

/// The parsed form of one LRC document.
final class ParsedLrc {
  /// Creates a parse result.
  const ParsedLrc({required this.lines, required this.words});

  /// A document with nothing in it.
  static const ParsedLrc empty = ParsedLrc(
    lines: <SwayveLyricLine>[],
    words: null,
  );

  /// The timed lines, in ascending order.
  final List<SwayveLyricLine> lines;

  /// Word timing, when the document carried any, in the SDK's nested shape.
  ///
  /// `null` rather than an empty list when the document had none, because the
  /// SDK treats "this lyric has no words" and "this provider does not do word
  /// timing" as different claims and only the second is true of a plain LRC
  /// file.
  final List<List<SwayveLyricWord>>? words;

  /// Whether anything at all was parsed.
  bool get isEmpty => lines.isEmpty;
}

/// Parses an LRC document.
///
/// Returns [ParsedLrc.empty] for a body that carries no usable timestamped
/// line, which covers a metadata-only file, an error page served with the wrong
/// content type, and an empty string.
ParsedLrc parseLrc(String body) {
  final List<LrcLine> parsed = <LrcLine>[];

  for (final String raw in body.split('\n')) {
    // Trimmed at both ends before the scan: a stamp is only recognised at the
    // head of the line, and a file indented for readability would otherwise
    // parse to nothing at all.
    final String line = raw.trim();
    if (line.isEmpty) continue;

    // Every timestamp at the head of the line, and only at the head. A file
    // may repeat a refrain by prefixing one text with several stamps, so this
    // collects them all and emits the text once per stamp.
    //
    // "At the head" is what keeps `[ar:The Weeknd]` and friends out: a
    // metadata tag does not match a timestamp, so the scan stops at offset
    // zero and the line is dropped. It is also what stops a bracketed clause
    // *inside* a lyric — `[Chorus]`, `[Verse 2]` — from being read as timing.
    final List<Duration> stamps = <Duration>[];
    int offset = 0;
    while (true) {
      final Match? match = _lineStamp.matchAsPrefix(line, offset);
      if (match == null) break;
      final Duration? at = _durationOf(match);
      // A stamp that matched the shape but not the arithmetic — there is no
      // such value today, and there may be tomorrow — costs the whole line
      // rather than silently shifting the rest of it earlier.
      if (at == null) {
        stamps.clear();
        break;
      }
      stamps.add(at);
      offset = match.end;
    }
    if (stamps.isEmpty) continue;

    final String remainder = line.substring(offset);
    final List<(Duration, String)> words = _wordsOf(remainder);
    // The stamps come out and the whitespace they were sitting in is
    // collapsed, so that an enhanced line reads exactly as the same line
    // without the markup would. Removed rather than replaced with a space:
    // some producers split a word across two stamps with nothing between them,
    // and a space there would break the word in half.
    final String text =
        remainder.replaceAll(_wordStamp, '').replaceAll(_spacing, ' ').trim();

    for (int stamp = 0; stamp < stamps.length; stamp++) {
      parsed.add(
        LrcLine(
          at: stamps[stamp],
          text: text,
          // A refrain repeated by a second stamp would inherit the first
          // stamp's word timings, which are wrong by however far apart the two
          // choruses are. Enhanced markup and multi-stamp lines do not co-occur
          // in practice, and where they did, wrong word timing is exactly the
          // kind of confident nonsense this plugin refuses to produce — so only
          // the first stamp keeps the words.
          words: stamp == 0 ? words : const <(Duration, String)>[],
        ),
      );
    }
  }

  if (parsed.isEmpty) return ParsedLrc.empty;
  parsed.sort((LrcLine a, LrcLine b) => a.at.compareTo(b.at));

  final List<SwayveLyricLine> lines = <SwayveLyricLine>[
    for (final LrcLine line in parsed)
      SwayveLyricLine(at: line.at, text: line.text),
  ];

  final List<List<SwayveLyricWord>> words = <List<SwayveLyricWord>>[];
  for (int i = 0; i < parsed.length; i++) {
    if (parsed[i].words.isEmpty) continue;
    final Duration? nextLineAt =
        i + 1 < parsed.length ? parsed[i + 1].at : null;
    words.add(_timedWords(parsed[i].words, nextLineAt: nextLineAt));
  }

  return ParsedLrc(
    lines: List<SwayveLyricLine>.unmodifiable(lines),
    words:
        words.isEmpty ? null : List<List<SwayveLyricWord>>.unmodifiable(words),
  );
}

/// The same lines joined into one plain-text lyric, or `null` when there are
/// none.
///
/// Published alongside the synced form rather than instead of it: the SDK asks
/// a provider that has one to fill in the other, because the surfaces that
/// cannot scroll in time still want the words.
String? plainFromLines(List<SwayveLyricLine> lines) {
  if (lines.isEmpty) return null;
  final String text =
      lines.map((SwayveLyricLine line) => line.text).join('\n').trim();
  return text.isEmpty ? null : text;
}

/// The word stamps in [remainder], each paired with the text that follows it.
List<(Duration, String)> _wordsOf(String remainder) {
  final List<RegExpMatch> stamps = _wordStamp.allMatches(remainder).toList();
  if (stamps.isEmpty) return const <(Duration, String)>[];

  final List<(Duration, String)> words = <(Duration, String)>[];
  for (int i = 0; i < stamps.length; i++) {
    final Duration? at = _durationOf(stamps[i]);
    if (at == null) continue;
    final int from = stamps[i].end;
    final int to =
        i + 1 < stamps.length ? stamps[i + 1].start : remainder.length;
    final String text = remainder.substring(from, to).trim();
    // A trailing stamp with nothing after it is the line's own end marker,
    // which some producers write. It is not a word; it is dropped here and
    // picked up again in [_timedWords] as the last word's end.
    if (text.isEmpty) continue;
    words.add((at, text));
  }
  return words;
}

/// [words] with an end put on each one.
///
/// Every word but the last ends where the next begins. The last is held for
/// [kFinalWordHold], or until [nextLineAt] if that comes sooner.
List<SwayveLyricWord> _timedWords(
  List<(Duration, String)> words, {
  required Duration? nextLineAt,
}) {
  final List<SwayveLyricWord> timed = <SwayveLyricWord>[];
  for (int i = 0; i < words.length; i++) {
    final (Duration at, String text) = words[i];
    Duration until;
    if (i + 1 < words.length) {
      until = words[i + 1].$1;
    } else {
      until = at + kFinalWordHold;
      if (nextLineAt != null && nextLineAt < until) until = nextLineAt;
    }
    // `until` is never before `at`, which the SDK states as a guarantee rather
    // than a hope. A file whose stamps run backwards would otherwise produce
    // one, and that is a data problem for the plugin to absorb rather than
    // hand to the host.
    if (until < at) until = at;
    timed.add(SwayveLyricWord(at: at, until: until, text: text));
  }
  return List<SwayveLyricWord>.unmodifiable(timed);
}

/// The duration a timestamp match names, or `null` when it does not name one.
Duration? _durationOf(Match match) {
  final int? minutes = int.tryParse(match.group(1)!);
  final int? seconds = int.tryParse(match.group(2)!);
  if (minutes == null || seconds == null) return null;

  final String? fraction = match.group(3);
  int milliseconds = 0;
  if (fraction != null) {
    final int? value = int.tryParse(fraction);
    if (value == null) return null;
    // Two digits are centiseconds and three are milliseconds. One digit is
    // read as tenths, which is what the only files that write it mean.
    milliseconds = switch (fraction.length) {
      1 => value * 100,
      2 => value * 10,
      _ => value,
    };
  }

  return Duration(
    minutes: minutes,
    seconds: seconds,
    milliseconds: milliseconds,
  );
}
