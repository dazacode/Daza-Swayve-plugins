import 'package:lyrics/lyrics.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The TTML parser's tests.
///
/// The fixture is the real document BetterLyrics returned for "Blinding
/// Lights", trimmed to two `<div>`s and otherwise untouched — including the
/// background-vocal element, which is the one shape a flat regular expression
/// gets catastrophically wrong.
void main() {
  final String document =
      fixtureMap('betterlyrics_ttml.json')['ttml']! as String;
  final ParsedTtml parsed = parseTtml(document);

  group('a real BetterLyrics document', () {
    test('reads the lines', () {
      expect(parsed.lines, hasLength(5));
      expect(parsed.lines.first.text, 'I been tryna call');
      expect(
        parsed.lines.first.at,
        const Duration(seconds: 27, milliseconds: 395),
      );
    });

    test('reads word timing for every line', () {
      expect(parsed.words, isNotNull);
      expect(
        parsed.words,
        hasLength(parsed.lines.length),
        reason: 'A words list shorter than the lines list is one a host would '
            'read against the wrong line.',
      );
      expect(
        parsed.words!.first.map((SwayveLyricWord w) => w.text),
        <String>['I', 'been', 'tryna', 'call'],
      );
    });

    test('every word carries a real end, not an inferred one', () {
      // This is the difference between this source and enhanced LRC: Apple's
      // documents time both edges of every word, so nothing here is a guess.
      final SwayveLyricWord first = parsed.words!.first.first;
      expect(first.at, const Duration(seconds: 27, milliseconds: 395));
      expect(first.until, const Duration(seconds: 27, milliseconds: 549));
    });

    test('reads a word split across syllables without inserting a space', () {
      // `<span>e</span><span>nough</span>` — two timed spans, one word. The
      // words list keeps them apart, because that is what the karaoke view
      // lights; the line text must still read "enough".
      final SwayveLyricLine line = parsed.lines[1];
      expect(line.text, "I've been on my own for long enough");
      expect(
        parsed.words![1].map((SwayveLyricWord w) => w.text),
        containsAllInOrder(<String>['e', 'nough']),
      );
    });

    test('reads the running time off the body', () {
      // The only fact in the whole document that can be checked against the
      // track. `3:21.570` — minutes, seconds and milliseconds in one value.
      expect(
        parsed.duration,
        const Duration(minutes: 3, seconds: 21, milliseconds: 570),
      );
    });

    test('every line is in ascending order and so is every word', () {
      for (var i = 1; i < parsed.lines.length; i++) {
        expect(parsed.lines[i].at >= parsed.lines[i - 1].at, isTrue);
      }
      for (final List<SwayveLyricWord> line in parsed.words!) {
        for (var i = 1; i < line.length; i++) {
          expect(line[i].at >= line[i - 1].at, isTrue);
          expect(line[i].until >= line[i].at, isTrue);
        }
      }
    });
  });

  group('background vocals', () {
    // The fixture's fourth line is `I'm just calling back to let you know`
    // with `(Back to let you know)` sung over the top of it as
    // `<span ttm:role="x-bg">…</span>`.
    final SwayveLyricLine background = parsed.lines[3];

    test('are not interleaved into the lead line\'s words', () {
      expect(
        parsed.words![3].map((SwayveLyricWord w) => w.text).join(' '),
        "I'm just calling back to let you know",
      );
      expect(
        parsed.words![3].map((SwayveLyricWord w) => w.text),
        isNot(contains('(Back')),
        reason: 'The background phrase starts before the lead line has '
            'finished. Interleaving would produce word timings that run '
            'backwards, which is not something the SDK\'s model can express.',
      );
    });

    test('are dropped from the line text too, so the two agree', () {
      expect(background.text, "I'm just calling back to let you know");
      expect(
        background.text,
        isNot(contains('(Back')),
        reason: 'A host lighting the words across the line text needs them to '
            'be the same words.',
      );
    });

    test('the outer wrapper is never mistaken for a word', () {
      // A non-greedy `<span…>(.*?)</span>` pairs the outer open tag with the
      // first inner close tag and yields a "word" reading "(Back". Nothing in
      // the parsed output may look like that.
      for (final List<SwayveLyricWord> line in parsed.words!) {
        for (final SwayveLyricWord word in line) {
          expect(word.text, isNot(contains('<')));
          expect(word.text.split(' '), hasLength(1));
        }
      }
    });
  });

  group('time values', () {
    test('accepts every form the observed documents use', () {
      expect(parseTtmlTime('27.395'), const Duration(milliseconds: 27395));
      expect(parseTtmlTime('1:00.964'), const Duration(milliseconds: 60964));
      expect(parseTtmlTime('3:21.570'), const Duration(milliseconds: 201570));
      expect(
        parseTtmlTime('1:02:03.500'),
        const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500),
      );
      expect(parseTtmlTime('0'), Duration.zero);
    });

    test('refuses the forms it cannot honestly read', () {
      // Frames and ticks need a rate the document does not carry, and a
      // guessed rate puts every word in the wrong place.
      expect(parseTtmlTime('120t'), isNull);
      expect(parseTtmlTime('00:00:01:12'), isNull);
      expect(parseTtmlTime('-1.0'), isNull);
      expect(parseTtmlTime('abc'), isNull);
      expect(parseTtmlTime(''), isNull);
      expect(parseTtmlTime(null), isNull);
    });
  });

  group('what must not parse into a lyric', () {
    test('a document with no body', () {
      expect(parseTtml('<tt><head><metadata/></head></tt>').isEmpty, isTrue);
    });

    test('a body with no lines', () {
      expect(parseTtml('<tt><body dur="1:00"></body></tt>').isEmpty, isTrue);
    });

    test('something that is not XML at all', () {
      expect(parseTtml('{"error":"API key required"}').isEmpty, isTrue);
      expect(parseTtml('').isEmpty, isTrue);
    });

    test('a line with no begin and no timed span', () {
      expect(parseTtml('<tt><body><p>words</p></body></tt>').isEmpty, isTrue);
    });
  });

  group('the line-timed variant', () {
    // `itunes:timing="Line"` documents exist — the same service returns them
    // for recordings Apple has not word-timed — and they have `<p>` elements
    // with no spans inside.
    final ParsedTtml lineTimed = parseTtml(
      '<tt itunes:timing="Line"><body dur="0:30.000">'
      '<div begin="1.000" end="10.000">'
      '<p begin="1.000" end="4.000">First line</p>'
      '<p begin="5.000" end="9.000">Second line</p>'
      '</div></body></tt>',
    );

    test('reads the lines', () {
      expect(lineTimed.lines, hasLength(2));
      expect(lineTimed.lines.first.text, 'First line');
      expect(lineTimed.lines.first.at, const Duration(seconds: 1));
    });

    test('claims no word timing, because there is none', () {
      expect(
        lineTimed.words,
        isNull,
        reason: 'The SDK asks a provider not to claim a capability it does '
            'not have for this document.',
      );
    });
  });

  test('a half-word-timed document claims no word timing at all', () {
    // The dangerous middle case: some lines timed, some not. A `words` list
    // with fewer entries than `synced` does not line up, and the SDK is
    // explicit that a host may read the two independently.
    final ParsedTtml mixed = parseTtml(
      '<tt><body dur="0:30.000"><div begin="1.000" end="10.000">'
      '<p begin="1.000" end="4.000">'
      '<span begin="1.000" end="2.000">First</span> '
      '<span begin="2.000" end="4.000">line</span></p>'
      '<p begin="5.000" end="9.000">Second line</p>'
      '</div></body></tt>',
    );
    expect(mixed.lines, hasLength(2));
    expect(mixed.words, isNull);
  });

  test('entities are decoded', () {
    final ParsedTtml entities = parseTtml(
      '<tt><body dur="0:10.000"><div begin="0" end="5">'
      '<p begin="1.000" end="4.000">'
      '<span begin="1.000" end="2.000">Rock&amp;Roll</span> '
      '<span begin="2.000" end="4.000">don&#39;t</span></p>'
      '</div></body></tt>',
    );
    expect(entities.lines.single.text, "Rock&Roll don't");
    expect(entities.words!.single.first.text, 'Rock&Roll');
  });
}
