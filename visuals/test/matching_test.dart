import 'package:test/test.dart';
import 'package:visuals/visuals.dart';

/// The rules both sources now share.
///
/// Worth its own file because the extraction is the point: these used to be
/// private to the TIDAL client, and a second copy inside the Spotify client
/// would have drifted until the background depended on which source answered
/// first. Pinning the thresholds here is what stops that.
void main() {
  group('normalizeForMatch', () {
    test('drops the trailers two catalogues disagree about', () {
      expect(normalizeForMatch('Song (Remastered 2011)'), 'song');
      expect(normalizeForMatch('Song [Explicit]'), 'song');
      expect(normalizeForMatch('Song (feat. Someone)'), 'song');
    });

    test('reduces punctuation and case to plain words', () {
      expect(normalizeForMatch("Don't Stop Me Now!"), 'don t stop me now');
      expect(normalizeForMatch('  MULTIPLE   SPACES  '), 'multiple spaces');
    });

    test('a title that is entirely a trailer normalizes to nothing', () {
      expect(normalizeForMatch('(Interlude)'), '');
      expect(normalizeForMatch(''), '');
    });
  });

  group('tokenOverlap', () {
    test('is 1 for the same words in any order', () {
      expect(tokenOverlap('one two', 'two one'), 1);
    });

    test('is 0 when nothing is shared', () {
      expect(tokenOverlap('one two', 'three four'), 0);
      expect(tokenOverlap('', 'anything'), 0);
    });

    test('is the Jaccard ratio in between', () {
      // {a,b} vs {b,c}: one shared word out of three distinct.
      expect(tokenOverlap('a b', 'b c'), closeTo(1 / 3, 0.001));
    });
  });

  group('titlesAgree', () {
    test('accepts an exact match and a bracketed variant of it', () {
      expect(titlesAgree('Alien Superstar', 'ALIEN SUPERSTAR'), isTrue);
      expect(
        titlesAgree('Alien Superstar', 'Alien Superstar (Remastered)'),
        isTrue,
      );
    });

    test('accepts a suffix a catalogue added', () {
      expect(titlesAgree('Song', 'Song - Radio Edit'), isTrue);
    });

    test('rejects a different song', () {
      expect(titlesAgree('Alien Superstar', 'Cuff It'), isFalse);
    });

    test('rejects when either side normalizes away to nothing', () {
      expect(titlesAgree('', 'Anything'), isFalse);
      expect(titlesAgree('Anything', '(Interlude)'), isFalse);
    });
  });

  group('artistsAgree', () {
    test('accepts any one of several credited artists', () {
      expect(artistsAgree('Beyonce', <String>['Drake', 'Beyonce']), isTrue);
    });

    test('is looser than titles, because credits differ more', () {
      // Half the words is enough here; titles need seven in ten.
      expect(
        artistsAgree('Calvin Harris', <String>['Calvin Harris & Dua Lipa']),
        isTrue,
      );
    });

    test('rejects an unrelated artist', () {
      expect(artistsAgree('Beyonce', <String>['Metallica']), isFalse);
      expect(artistsAgree('Beyonce', const <String>[]), isFalse);
    });

    test('an unknown wanted artist agrees with anything', () {
      // Nothing to disagree with is not a disagreement — the title and
      // duration gates still apply.
      expect(artistsAgree('', <String>['Anyone']), isTrue);
    });
  });

  group('durationsAgree', () {
    test('accepts a difference inside the tolerance', () {
      expect(
        durationsAgree(
          const Duration(seconds: 216),
          const Duration(seconds: 220),
        ),
        isTrue,
      );
      expect(kMatchDurationTolerance, const Duration(seconds: 20));
    });

    test('rejects a remix-sized difference', () {
      expect(
        durationsAgree(
          const Duration(seconds: 216),
          const Duration(seconds: 400),
        ),
        isFalse,
      );
    });

    test('a missing duration on either side is not a disagreement', () {
      // Plenty of catalogues report none, and refusing all of them would
      // throw away more correct matches than the check saves.
      expect(durationsAgree(null, const Duration(seconds: 216)), isTrue);
      expect(durationsAgree(const Duration(seconds: 216), null), isTrue);
      expect(durationsAgree(null, null), isTrue);
    });

    test('the boundary itself is accepted', () {
      expect(
        durationsAgree(
          const Duration(seconds: 200),
          const Duration(seconds: 220),
        ),
        isTrue,
      );
      expect(
        durationsAgree(
          const Duration(seconds: 200),
          const Duration(seconds: 221),
        ),
        isFalse,
      );
    });
  });
}
