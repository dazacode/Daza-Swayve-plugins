import 'package:lyrics/lyrics.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The LRC parser's tests.
///
/// The committed fixture is a real LRCLIB record, so the first group proves the
/// parser reads what the service actually sends. Everything after it is a hand
/// written edge case, because the shapes worth guarding against — a malformed
/// stamp, a metadata header, a lyric containing square brackets — are precisely
/// the ones a well-behaved service never sends and something else eventually
/// will.
void main() {
  group('a real LRCLIB record', () {
    final ParsedLrc parsed = parseLrc(
      fixtureMap('lrclib_get.json')['syncedLyrics']! as String,
    );

    test('reads every line, in order', () {
      expect(parsed.lines, hasLength(8));
      expect(
        parsed.lines.first.at,
        const Duration(seconds: 13, milliseconds: 130),
      );
      expect(parsed.lines.first.text, 'Yeah');
      expect(
        parsed.lines.last.text,
        'You can turn me on with just a touch, baby',
      );
      for (var i = 1; i < parsed.lines.length; i++) {
        expect(
          parsed.lines[i].at >= parsed.lines[i - 1].at,
          isTrue,
          reason: 'Line $i goes backwards.',
        );
      }
    });

    test('reads centiseconds as centiseconds', () {
      // `[00:29.96]` is 29.96 seconds, not 29 seconds and 96 milliseconds. Off
      // by a factor of ten is the classic way to get this wrong, and it looks
      // almost right on a short song.
      expect(
        parsed.lines[3].at,
        const Duration(seconds: 29, milliseconds: 960),
      );
    });

    test('keeps the instrumental marker as a line of its own', () {
      // LRCLIB writes a `♪` for a passage with no words. It is a real line at a
      // real time and dropping it would leave the previous lyric on screen
      // through the whole break.
      expect(parsed.lines[1].text, '♪');
    });

    test('claims no word timing, because the record carries none', () {
      expect(
        parsed.words,
        isNull,
        reason: '`null` rather than an empty list: "this lyric has no words" '
            'and "this document does not carry word timing" are different '
            'claims and only the second is true.',
      );
    });

    test('flattens to a plain lyric for the surfaces that cannot scroll', () {
      final String? plain = plainFromLines(parsed.lines);
      expect(plain, startsWith('Yeah\n♪\n'));
      expect(plain, isNot(contains('[')));
    });
  });

  group('timestamps', () {
    test('accepts two-digit, three-digit and absent fractions', () {
      final ParsedLrc parsed = parseLrc(
        '[00:01.5] tenths\n'
        '[00:02.50] centiseconds\n'
        '[00:03.500] milliseconds\n'
        '[00:04] none\n',
      );
      expect(parsed.lines.map((SwayveLyricLine l) => l.at), <Duration>[
        const Duration(milliseconds: 1500),
        const Duration(milliseconds: 2500),
        const Duration(milliseconds: 3500),
        const Duration(milliseconds: 4000),
      ]);
    });

    test('accepts the older colon separator', () {
      expect(
        parseLrc('[00:05:25] old').lines.single.at,
        const Duration(milliseconds: 5250),
      );
    });

    test('handles a track past an hour without wrapping', () {
      expect(
        parseLrc('[100:00.00] long').lines.single.at,
        const Duration(minutes: 100),
      );
    });
  });

  group('what must not become a lyric line', () {
    test('a metadata header', () {
      final ParsedLrc parsed = parseLrc(
        '[ar:The Weeknd]\n'
        '[ti:Blinding Lights]\n'
        '[length:03:20]\n'
        '[00:13.13] Yeah\n',
      );
      expect(parsed.lines, hasLength(1));
      expect(parsed.lines.single.text, 'Yeah');
    });

    test('a section marker inside the lyric', () {
      // `[Chorus]` sits after the timestamp, not before it, so it is text.
      final ParsedLrc parsed = parseLrc('[00:13.13] [Chorus] Yeah\n');
      expect(parsed.lines.single.text, '[Chorus] Yeah');
    });

    test('a line with no timestamp at all', () {
      expect(parseLrc('Just some words\n').isEmpty, isTrue);
    });

    test('a body that is not LRC', () {
      expect(parseLrc('<html><body>404</body></html>').isEmpty, isTrue);
      expect(parseLrc('').isEmpty, isTrue);
      expect(parseLrc('   \n\n  ').isEmpty, isTrue);
    });

    test('a malformed stamp costs its line and nothing else', () {
      final ParsedLrc parsed = parseLrc(
        '[00:99.13] impossible seconds\n'
        '[xx:yy.zz] not numbers\n'
        '[00:13.13] fine\n',
      );
      expect(parsed.lines, hasLength(1));
      expect(parsed.lines.single.text, 'fine');
    });
  });

  group('the awkward shapes', () {
    test('one text under several stamps becomes several lines', () {
      final ParsedLrc parsed = parseLrc(
        '[01:02.44][02:31.10] I said, ooh\n',
      );
      expect(parsed.lines, hasLength(2));
      expect(
        parsed.lines[0].at,
        const Duration(minutes: 1, seconds: 2, milliseconds: 440),
      );
      expect(
        parsed.lines[1].at,
        const Duration(minutes: 2, seconds: 31, milliseconds: 100),
      );
      expect(parsed.lines[0].text, parsed.lines[1].text);
    });

    test('a blank line keeps its timestamp', () {
      // Some producers mark an instrumental with an empty line rather than a
      // `♪`. The SDK says a line's text may be empty for exactly this, so it
      // survives.
      final ParsedLrc parsed = parseLrc('[00:14.81] \n[00:26.95] words\n');
      expect(parsed.lines, hasLength(2));
      expect(parsed.lines.first.text, isEmpty);
    });

    test('a record written without a space after the bracket', () {
      // Observed on LRCLIB: some submissions have it, some do not.
      expect(parseLrc('[00:13.42]Yeah').lines.single.text, 'Yeah');
    });

    test('lines out of order are sorted', () {
      final ParsedLrc parsed = parseLrc('[00:20.00] b\n[00:10.00] a\n');
      expect(
        parsed.lines.map((SwayveLyricLine l) => l.text),
        <String>['a', 'b'],
      );
    });
  });

  group('enhanced LRC', () {
    final ParsedLrc parsed = parseLrc(
      '[00:27.16] <00:27.16> I\'ve <00:27.55> been <00:27.74> tryna '
      '<00:28.08> call\n'
      '[00:29.96] <00:29.96> I\'ve <00:30.40> been\n',
    );

    test('produces one list of words per line', () {
      expect(parsed.words, isNotNull);
      expect(parsed.words, hasLength(2));
      expect(parsed.words![0], hasLength(4));
      expect(
        parsed.words![0].map((SwayveLyricWord w) => w.text),
        <String>["I've", 'been', 'tryna', 'call'],
      );
    });

    test('a word ends where the next one begins', () {
      expect(parsed.words![0][0].at, const Duration(milliseconds: 27160));
      expect(parsed.words![0][0].until, const Duration(milliseconds: 27550));
      expect(parsed.words![0][1].at, parsed.words![0][0].until);
    });

    test('the last word of a line is held, capped by the next line', () {
      // The next line starts 1.88s after the last word of this one, which is
      // inside the two-second hold, so the cap is what applies.
      expect(parsed.words![0].last.at, const Duration(milliseconds: 28080));
      expect(
        parsed.words![0].last.until,
        const Duration(milliseconds: 29960),
        reason: 'Capped at the next line rather than held the full two '
            'seconds, so nothing stays lit into the following phrase.',
      );
    });

    test('the very last word gets the full hold, since nothing caps it', () {
      expect(
        parsed.words![1].last.until,
        parsed.words![1].last.at + kFinalWordHold,
      );
    });

    test('the line text has the word stamps taken out of it', () {
      expect(parsed.lines.first.text, "I've been tryna call");
    });

    test('a trailing end stamp is not read as an empty word', () {
      final ParsedLrc trailing =
          parseLrc('[00:10.00] <00:10.00> one <00:11.00> two <00:12.00>\n');
      expect(trailing.words!.single, hasLength(2));
      expect(trailing.lines.single.text, 'one two');
    });

    test('a repeated refrain does not inherit the first chorus\'s timings', () {
      final ParsedLrc repeated =
          parseLrc('[01:00.00][02:00.00] <01:00.00> la <01:00.50> la\n');
      expect(repeated.lines, hasLength(2));
      expect(
        repeated.words,
        hasLength(1),
        reason: 'The second stamp is a minute later; carrying the first '
            'stamp\'s word timings over would light the wrong second of the '
            'song for the whole chorus.',
      );
    });

    test('a word never ends before it starts, even if the file says so', () {
      final ParsedLrc backwards =
          parseLrc('[00:10.00] <00:11.00> late <00:10.00> early\n');
      for (final SwayveLyricWord word in backwards.words!.single) {
        expect(word.until >= word.at, isTrue);
      }
    });
  });
}
