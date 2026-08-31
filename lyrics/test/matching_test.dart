import 'package:lyrics/lyrics.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// The tests for the part most likely to be wrong.
///
/// Two failures are possible here and they are not symmetrical. Refusing a
/// match that was right costs a listener a lyric they could have had. Accepting
/// a match that was wrong shows them another song's words and, if it is synced,
/// scrolls them past at the wrong moment for four minutes. The second is much
/// worse, so the "must refuse" group below is the one that matters, and it is
/// deliberately longer than the "must accept" one.
void main() {
  group('normalization', () {
    test('folds case', () {
      expect(normalizeForComparison('SICKO MODE'), 'sicko mode');
    });

    test('collapses whitespace, including the runs a scraper leaves behind',
        () {
      expect(normalizeForComparison('  SICKO   MODE\t'), 'sicko mode');
    });

    test('folds diacritics to the letter underneath', () {
      expect(normalizeForComparison('Björk'), 'bjork');
      expect(normalizeForComparison('Beyoncé'), 'beyonce');
      expect(normalizeForComparison('Sigur Rós'), 'sigur ros');
      expect(normalizeForComparison('Motörhead'), 'motorhead');
      expect(normalizeForComparison('Ænima'), 'aenima');
      expect(normalizeForComparison('Straße'), 'strasse');
    });

    test('leaves a non-Latin script alone rather than inventing a spelling',
        () {
      // The plugin does not romanize, on purpose — that needs a dictionary and
      // the dictionary packages bring their own HTTP stack. A Japanese title
      // compares as itself, which works perfectly well as long as both sides
      // spell it the same way, and fails honestly when they do not.
      expect(normalizeForComparison('前前前世'), '前前前世');
      expect(
        normalizeForComparison('Ой у лузі червона калина'),
        'ой у лузі червона калина',
      );
    });

    test('drops bracketed decoration in every bracket the platforms use', () {
      expect(
        normalizeForComparison('Blinding Lights (Official Video)'),
        'blinding lights',
      );
      expect(
        normalizeForComparison('Bohemian Rhapsody [Remastered 2011]'),
        'bohemian rhapsody',
      );
      expect(normalizeForComparison('前前前世 【MV】'), '前前前世');
      expect(
        normalizeForComparison('Sicko Mode (feat. Drake)'),
        'sicko mode',
      );
    });

    test('drops punctuation, which is where the quiet mismatches live', () {
      // A curly apostrophe against a straight one is the single most common
      // way two catalogues disagree about a title while meaning the same thing.
      expect(
        normalizeForComparison('Don’t Stop Me Now'),
        normalizeForComparison("Don't Stop Me Now"),
      );
      expect(
        normalizeForComparison('Marquee Moon — Live'),
        normalizeForComparison('Marquee Moon - Live'),
      );
    });

    test('takes a platform suffix off a credit', () {
      expect(normalizeArtistForComparison('The Weeknd - Topic'), 'the weeknd');
      expect(normalizeArtistForComparison('The Weeknd - topic'), 'the weeknd');
      expect(normalizeArtistForComparison('EminemVEVO'), 'eminem');
      expect(
        normalizeArtistForComparison('Radiohead'),
        'radiohead',
        reason: 'A credit with no suffix must survive the rule intact.',
      );
    });

    test('does not amputate a name that merely ends in one of those words', () {
      // `- Topic` is anchored to the end and requires the dash, so a band
      // actually called this keeps its name.
      expect(
        normalizeArtistForComparison('Topic'),
        'topic',
        reason: 'There is a producer called Topic and he is not a YouTube '
            'auto-generated channel.',
      );
    });

    test('the wire form keeps what the comparison form throws away', () {
      // The two cleanings are for different audiences. A service matching
      // against its own catalogue is better at diacritics and punctuation than
      // this plugin is, so it gets the real text.
      expect(lightlyCleaned('Björk (Live)'), 'Björk');
      expect(lightlyCleaned("Don't Stop Me Now"), "Don't Stop Me Now");
    });
  });

  group('building a query from another plugin\'s track', () {
    test('cleans the title and the credit but keeps them readable', () {
      final LyricsQuery query = LyricsQuery.fromTrack(blindingLights())!;
      expect(query.title, 'Blinding Lights');
      expect(query.artist, 'The Weeknd');
      expect(query.album, 'After Hours');
      expect(query.duration, const Duration(seconds: 200));
    });

    test('compares on the stripped title, which pairs both spellings', () {
      final LyricsQuery query = LyricsQuery.fromTrack(blindingLights())!;
      expect(query.comparableTitles, <String>{'blinding lights'});
      expect(
        query.verdictFor(
          candidateTitle: 'Blinding Lights (Official Video)',
          candidateArtist: 'The Weeknd',
          candidateDuration: const Duration(seconds: 200),
        ),
        LyricsMatch.timed,
        reason: 'The clause is dropped from both sides, so a record that kept '
            'it and a track that did not still agree. Holding a second, '
            'unstripped spelling would add nothing.',
      );
    });

    test(
        'a live take is separated from the studio cut by its length, not its '
        'title', () {
      // The cost of stripping brackets, named: `Song (Live)` and `Song` reduce
      // to the same string. The duration check is what keeps them apart, and
      // it is why the tolerance is two seconds rather than something generous.
      final LyricsQuery live = LyricsQuery.fromTrack(
        blindingLights(
          title: 'Blinding Lights (Live at the O2)',
          duration: const Duration(seconds: 244),
        ),
      )!;
      expect(live.comparableTitles, <String>{'blinding lights'});
      expect(
        live.verdictFor(
          candidateTitle: 'Blinding Lights',
          candidateArtist: 'The Weeknd',
          candidateDuration: const Duration(seconds: 200),
        ),
        LyricsMatch.rejected,
      );
    });

    test('holds every credit, not just the one it will send', () {
      final SwayveTrack collaboration = SwayveTrack(
        id: const SwayveMediaId('app.swayve.plugins.soundcloud', '1'),
        title: 'Sicko Mode',
        artists: const <SwayveArtistRef>[
          SwayveArtistRef(name: 'Travis Scott'),
          SwayveArtistRef(name: 'Drake'),
        ],
        duration: const Duration(seconds: 312),
      );
      final LyricsQuery query = LyricsQuery.fromTrack(collaboration)!;
      expect(query.artist, 'Travis Scott');
      expect(
        query.comparableArtists,
        <String>{'travis scott', 'drake'},
        reason: 'The two services disagree about which artist is primary, and '
            'this plugin has no business insisting on an answer.',
      );
    });

    test('refuses a track with no credit rather than guessing from the title',
        () {
      final SwayveTrack anonymous = SwayveTrack(
        id: const SwayveMediaId('app.swayve.plugins.soundcloud', '2'),
        title: 'Untitled Demo',
        duration: const Duration(seconds: 128),
      );
      expect(
        LyricsQuery.fromTrack(anonymous),
        isNull,
        reason: 'A bare title matches whatever cover was uploaded most '
            'recently, and the lyric would be confidently wrong.',
      );
    });

    test('refuses a track whose title is nothing but decoration', () {
      final SwayveTrack empty = SwayveTrack(
        id: const SwayveMediaId('app.swayve.plugins.soundcloud', '3'),
        title: '(Official Audio)',
        artists: const <SwayveArtistRef>[SwayveArtistRef(name: 'Somebody')],
      );
      expect(LyricsQuery.fromTrack(empty), isNull);
    });
  });

  group('the verdict — what must be accepted', () {
    final LyricsQuery query = LyricsQuery.fromTrack(blindingLights())!;

    test('the same recording spelled the database\'s way', () {
      expect(
        query.verdictFor(
          candidateTitle: 'Blinding Lights',
          candidateArtist: 'The Weeknd',
          candidateDuration: const Duration(seconds: 200),
        ),
        LyricsMatch.timed,
      );
    });

    test('a running time inside the tolerance, at both edges', () {
      for (final int seconds in <int>[198, 199, 201, 202]) {
        expect(
          query.verdictFor(
            candidateTitle: 'Blinding Lights',
            candidateArtist: 'The Weeknd',
            candidateDuration: Duration(seconds: seconds),
          ),
          LyricsMatch.timed,
          reason: '$seconds seconds is within the two-second tolerance.',
        );
      }
    });
  });

  group('the verdict — what must be refused', () {
    final LyricsQuery query = LyricsQuery.fromTrack(blindingLights())!;

    test('a different song by the same artist', () {
      expect(
        query.verdictFor(
          candidateTitle: 'Save Your Tears',
          candidateArtist: 'The Weeknd',
          candidateDuration: const Duration(seconds: 200),
        ),
        LyricsMatch.rejected,
      );
    });

    test('the same title by a different artist — the cover-version trap', () {
      expect(
        query.verdictFor(
          candidateTitle: 'Blinding Lights',
          candidateArtist: 'Some Wedding Band',
          candidateDuration: const Duration(seconds: 200),
        ),
        LyricsMatch.rejected,
      );
    });

    test('a running time one second past the tolerance', () {
      for (final int seconds in <int>[197, 203]) {
        expect(
          query.verdictFor(
            candidateTitle: 'Blinding Lights',
            candidateArtist: 'The Weeknd',
            candidateDuration: Duration(seconds: seconds),
          ),
          LyricsMatch.rejected,
          reason: 'The tolerance is two seconds and it is not negotiable at '
              'the edge: this is what separates the album cut from the radio '
              'edit.',
        );
      }
    });

    test('the extended mix, which is the failure this whole file exists for',
        () {
      // Real numbers, from the observed LRCLIB search page for this recording:
      // five of the first six results were the same lyric filed under five
      // different compilations, running 202, 202, 202, 248 and 263 seconds.
      for (final int seconds in <int>[248, 263]) {
        expect(
          query.verdictFor(
            candidateTitle: 'Blinding Lights',
            candidateArtist: 'The Weeknd',
            candidateDuration: Duration(seconds: seconds),
          ),
          LyricsMatch.rejected,
        );
      }
    });

    test('a title that is one letter away from this one', () {
      // Edit distance would admit this, which is why there is none.
      expect(
        query.verdictFor(
          candidateTitle: 'Blinding Light',
          candidateArtist: 'The Weeknd',
          candidateDuration: const Duration(seconds: 200),
        ),
        LyricsMatch.rejected,
      );
    });
  });

  group('the verdict — when a running time is missing', () {
    test('a track with no duration gets the words and not the timings', () {
      final LyricsQuery query =
          LyricsQuery.fromTrack(blindingLights(duration: null))!;
      expect(
        query.verdictFor(
          candidateTitle: 'Blinding Lights',
          candidateArtist: 'The Weeknd',
          candidateDuration: const Duration(seconds: 200),
        ),
        LyricsMatch.plainOnly,
      );
    });

    test('a candidate with no duration is treated the same way', () {
      final LyricsQuery query = LyricsQuery.fromTrack(blindingLights())!;
      expect(
        query.verdictFor(
          candidateTitle: 'Blinding Lights',
          candidateArtist: 'The Weeknd',
        ),
        LyricsMatch.plainOnly,
      );
    });

    test('plainOnly strips the timings rather than trusting the caller', () {
      const SwayveLyrics full = SwayveLyrics(
        plain: 'Yeah',
        synced: <SwayveLyricLine>[
          SwayveLyricLine(at: Duration(seconds: 13), text: 'Yeah'),
        ],
        words: <List<SwayveLyricWord>>[
          <SwayveLyricWord>[
            SwayveLyricWord(
              at: Duration(seconds: 13),
              until: Duration(seconds: 14),
              text: 'Yeah',
            ),
          ],
        ],
        source: 'LRCLIB',
      );

      final SwayveLyrics trimmed = asPermittedBy(LyricsMatch.plainOnly, full)!;
      expect(trimmed.plain, 'Yeah');
      expect(trimmed.synced, isNull);
      expect(trimmed.words, isNull);
      expect(
        trimmed.source,
        'LRCLIB',
        reason: 'The attribution survives the trim — it describes where the '
            'words came from, and the words are still here.',
      );

      expect(asPermittedBy(LyricsMatch.timed, full), same(full));
      expect(asPermittedBy(LyricsMatch.rejected, full), isNull);
    });

    test('a synced-only document reduced to plain is nothing at all', () {
      const SwayveLyrics syncedOnly = SwayveLyrics(
        synced: <SwayveLyricLine>[
          SwayveLyricLine(at: Duration(seconds: 13), text: 'Yeah'),
        ],
        source: 'LRCLIB',
      );
      expect(
        asPermittedBy(LyricsMatch.plainOnly, syncedOnly),
        isNull,
        reason: 'Better nothing than a scroll that drifts.',
      );
    });
  });

  group('durations and ranking', () {
    test('a missing duration is not agreement', () {
      expect(durationsAgree(null, const Duration(seconds: 200)), isFalse);
      expect(durationsAgree(const Duration(seconds: 200), null), isFalse);
      expect(durationsAgree(null, null), isFalse);
    });

    test('word timing outranks synced outranks plain outranks nothing', () {
      const SwayveLyricLine line =
          SwayveLyricLine(at: Duration.zero, text: 'a');
      const SwayveLyricWord word = SwayveLyricWord(
        at: Duration.zero,
        until: Duration(seconds: 1),
        text: 'a',
      );
      expect(
        lyricsRank(
          const SwayveLyrics(
            words: <List<SwayveLyricWord>>[
              <SwayveLyricWord>[word],
            ],
          ),
        ),
        3,
      );
      expect(
        lyricsRank(const SwayveLyrics(synced: <SwayveLyricLine>[line])),
        2,
      );
      expect(lyricsRank(const SwayveLyrics(plain: 'a')), 1);
      expect(lyricsRank(const SwayveLyrics(plain: '   ')), 0);
      expect(lyricsRank(const SwayveLyrics()), 0);
    });
  });
}
