/// The part that decides whether a lyric belongs to a recording.
///
/// This is the file to distrust. Everything else in the plugin is a parser or
/// a request, and a parser that is wrong produces something visibly broken;
/// this produces something that looks completely fine and is the words to a
/// different song. A listener shown the wrong lyric does not conclude that the
/// match was poor. They conclude the app is broken, and they are not wrong.
///
/// So the rule everything here is written to is: **a wrong match is worse than
/// no match.** Where there is a choice between accepting a candidate and
/// refusing it, this refuses. `null` is a perfectly good answer and the host is
/// built to expect it, because most recordings genuinely have no lyric
/// anywhere.
///
/// ## Why a normalization step exists at all
///
/// The track this plugin is asked about did not come from either lyric
/// service. It came from YouTube Music, or SoundCloud, or a listener's own
/// iBroadcast library, and each of those spells a recording its own way:
///
/// * `Blinding Lights (Official Video)` against `Blinding Lights`;
/// * `The Weeknd - Topic` against `The Weeknd` — YouTube's auto-generated
///   artist channels append that, and it reaches this plugin inside the credit
///   string;
/// * `Björk` against `Bjork`, because a user-submitted database is typed on
///   whatever keyboard was to hand;
/// * `SICKO   MODE` against `Sicko Mode`.
///
/// Comparing those raw would refuse matches that are obviously right. So both
/// sides go through [normalizeForComparison] first and the comparison happens
/// between the results. Note what normalization is *not* used for: the strings
/// actually sent to a service are only lightly cleaned (see [LyricsQuery]),
/// because a service matching against its own catalogue wants the real text,
/// diacritics and all.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';

/// The letters that fold to an ASCII base, grouped by what they fold to.
///
/// Written as groups rather than as a flat pair-per-line map because a flat map
/// of ninety entries is a place for a typo to hide, and written out at all
/// rather than reached for through a package because a plugin's `lib/` is pure
/// Dart with the SDK as its only dependency.
///
/// This is a fold for *comparison*, not a transliteration: it exists so that
/// `Bjork` and `Björk` compare equal, and its output is never shown to anybody.
/// That is why it is confined to the Latin scripts, where dropping a diacritic
/// leaves a recognisable letter behind. A Cyrillic or CJK title passes through
/// untouched and is compared as itself, which is correct — there is no ASCII
/// letter underneath `の` to expose, and inventing one would be romanization.
/// Romanization is deliberately the host's job and not this plugin's: it needs
/// a dictionary, the dictionary package brings its own HTTP stack, and that is
/// the exact dependency the manifest's transport model forbids.
const List<(String, String)> kLetterFolding = <(String, String)>[
  ('a', 'àáâãäåāăąǎ'),
  ('e', 'èéêëēĕėęěȩ'),
  ('i', 'ìíîïĩīĭįıǐ'),
  ('o', 'òóôõöøōŏőǒ'),
  ('u', 'ùúûüũūŭůűųǔ'),
  ('y', 'ýÿŷ'),
  ('c', 'çćĉċč'),
  ('d', 'ďđð'),
  ('g', 'ĝğġģ'),
  ('h', 'ĥħ'),
  ('j', 'ĵ'),
  ('k', 'ķĸ'),
  ('l', 'ĺļľŀł'),
  ('n', 'ñńņňŉŋ'),
  ('r', 'ŕŗř'),
  ('s', 'śŝşšſ'),
  ('t', 'ţťŧ'),
  ('w', 'ŵ'),
  ('z', 'źżž'),
  // The ligatures and the one letter that is two letters. These are the reason
  // this table maps to a `String` rather than to a single character.
  ('ae', 'æǽ'),
  ('oe', 'œ'),
  ('ss', 'ß'),
  ('th', 'þ'),
];

final Map<int, String> _folding = <int, String>{
  for (final (String base, String accented) in kLetterFolding)
    for (final int rune in accented.runes) rune: base,
};

/// Bracketed groups, which normalization drops wholesale.
///
/// `(Official Video)`, `[Remastered 2011]`, `【MV】`, `(feat. Someone)`,
/// `(2019 Remaster)`. What they have in common is that they are decoration
/// added by whoever published *this* upload, and the lyric database knows
/// nothing about them.
///
/// This does cost something, and it is worth naming: a title that is genuinely
/// parenthesised — `(I Can't Get No) Satisfaction`, `(Don't Fear) The Reaper` —
/// loses a real part of itself here. That is survivable precisely because the
/// same rule is applied to *both* sides of every comparison, so the two strings
/// lose the same clause and still agree with each other.
final RegExp _bracketed = RegExp(r'[\(\[\{【（][^\)\]\}】）]*[\)\]\}】）]');

/// The suffixes a video platform appends to an artist's name.
///
/// `- Topic` is YouTube's marker for an auto-generated artist channel and
/// reaches this plugin inside the credit string of a great many tracks; `VEVO`
/// is the label-operated channel naming convention. Neither is part of
/// anybody's name.
final RegExp _artistSuffix = RegExp(
  r'\s*(-\s*topic|vevo|official)\s*$',
  caseSensitive: false,
);

final RegExp _punctuation = RegExp(r'[^\p{L}\p{N}\s]', unicode: true);

final RegExp _whitespace = RegExp(r'\s+');

/// [text] reduced to the form two spellings of the same thing share.
///
/// Case-folded, diacritic-folded, stripped of bracketed groups and of
/// punctuation, whitespace-collapsed. The result is for comparing and is never
/// displayed.
///
/// Punctuation goes last and goes entirely, which handles the family of
/// differences nothing else catches: a curly apostrophe against a straight one,
/// an en dash against a hyphen, a title that ends in an exclamation mark in one
/// catalogue and not in the other.
String normalizeForComparison(String text) {
  final StringBuffer folded = StringBuffer();
  for (final int rune in text.toLowerCase().replaceAll(_bracketed, ' ').runes) {
    folded.write(_folding[rune] ?? String.fromCharCode(rune));
  }
  return folded
      .toString()
      .replaceAll(_punctuation, ' ')
      .replaceAll(_whitespace, ' ')
      .trim();
}

/// [artist] with a platform's own suffix taken off, then normalized.
///
/// Applied on top of [normalizeForComparison] rather than instead of it,
/// because `The Weeknd - Topic` has to lose both the suffix and the case before
/// it looks like `The Weeknd`.
String normalizeArtistForComparison(String artist) =>
    normalizeForComparison(artist.replaceAll(_artistSuffix, ''));

/// [text] with bracketed decoration dropped and whitespace collapsed, but
/// otherwise left alone.
///
/// This is the cleaning applied to strings that go out on the wire, as opposed
/// to [normalizeForComparison], which is applied to strings being compared here.
String lightlyCleaned(String text) =>
    text.replaceAll(_bracketed, ' ').replaceAll(_whitespace, ' ').trim();

/// What a candidate is allowed to be used for.
///
/// Three outcomes rather than a boolean, because "is this the right recording"
/// and "are these timings the right timings" are different questions with
/// different costs attached to getting them wrong.
enum LyricsMatch {
  /// Not this recording. Nothing from this candidate may be used.
  rejected,

  /// The right song, but possibly not the right *cut* of it.
  ///
  /// Reached when a running time is missing on either side. Title and credit
  /// together do not identify a recording — a single, its album cut, its radio
  /// edit, a remaster and a live take all share both — so without a duration to
  /// tell them apart, the timings cannot be trusted. The words very probably
  /// can: two cuts of one song are overwhelmingly the same lyric.
  ///
  /// So this admits [SwayveLyrics.plain] and refuses [SwayveLyrics.synced] and
  /// [SwayveLyrics.words]. A plain lyric that came off the album cut instead of
  /// the radio edit is right; a *synced* one is a lyric that drifts further out
  /// of time with every chorus, which reads as a broken player rather than as a
  /// near miss.
  plainOnly,

  /// The right recording, running to the right length. Everything is usable.
  timed,
}

/// The strings this plugin sends to a lyric service, and the facts it checks an
/// answer against.
///
/// Two different jobs, deliberately held by one object, because they have to
/// stay consistent: the thing asked for and the thing the answer is checked
/// against must describe the same recording, and the surest way to keep that
/// true is to derive both from one place.
///
/// The wire strings ([title], [artist], [album]) are only *lightly* cleaned and
/// keep their case, their diacritics and their punctuation. A service matching
/// against its own catalogue is better at that than this plugin is, and handing
/// it `bjork` when the record says `Björk` would be throwing away the
/// information it needs.
final class LyricsQuery {
  /// Creates a query.
  const LyricsQuery({
    required this.title,
    required this.artist,
    this.album,
    this.duration,
    this.comparableTitles = const <String>{},
    this.comparableArtists = const <String>{},
  });

  /// The query a lyric service should be asked for [track], or `null` when the
  /// track does not carry enough to ask a useful question.
  ///
  /// "Enough" means a title and at least one credited artist. A title alone is
  /// not enough and this refuses to guess with it: both services match on the
  /// pair, a bare title matches whatever cover version was uploaded most
  /// recently, and the resulting lyric would be confidently wrong. A recording
  /// with no credit at all is uncommon in a real library, and losing its lyrics
  /// is the right trade.
  static LyricsQuery? fromTrack(SwayveTrack track) {
    final String title = lightlyCleaned(track.title);
    if (title.isEmpty) return null;

    final List<String> credits = <String>[
      for (final SwayveArtistRef artist in track.artists)
        artist.name.replaceAll(_artistSuffix, '').trim(),
    ]..removeWhere((String name) => name.isEmpty);
    if (credits.isEmpty) return null;

    final String album =
        track.album == null ? '' : lightlyCleaned(track.album!.title);

    return LyricsQuery(
      title: title,
      // The first credit only. Both services take one artist string, and a
      // featured-artist list joined back together is a string no catalogue
      // holds — the primary credit is the one every catalogue agrees on.
      artist: credits.first,
      album: album.isEmpty ? null : album,
      duration: track.duration,
      // One spelling, and it is deliberately the stripped one. Because
      // normalization drops bracketed clauses from *both* sides of every
      // comparison, `Blinding Lights (Official Video)` and `Blinding Lights`
      // arrive at the same string and no second variant is needed to pair
      // them — holding the unstripped form as well could only ever match
      // things the stripped form already matches.
      //
      // What it costs is that `Song (Live)` also agrees with the studio
      // `Song`, since both reduce to `song`. That is what the duration check
      // is for: a live take and a studio cut are not the same length, and the
      // verdict below refuses on the second test rather than the first.
      comparableTitles: <String>{normalizeForComparison(track.title)}
        ..removeWhere((String value) => value.isEmpty),
      // Every credit, not just the first, because the two services disagree
      // about which of a collaboration's artists is the primary one and this
      // plugin has no business insisting on an answer.
      comparableArtists: <String>{
        for (final String credit in credits)
          normalizeArtistForComparison(credit),
      }..removeWhere((String value) => value.isEmpty),
    );
  }

  /// The track title, lightly cleaned, as sent to a service.
  final String title;

  /// The primary credited artist, lightly cleaned, as sent to a service.
  final String artist;

  /// The album title, when the track carries one.
  final String? album;

  /// The recording's running time, when the track carries one.
  final Duration? duration;

  /// Every normalized spelling of the title that should be accepted.
  final Set<String> comparableTitles;

  /// Every normalized spelling of a credit that should be accepted.
  final Set<String> comparableArtists;

  /// What may be taken from a candidate calling itself [candidateTitle] by
  /// [candidateArtist] and running for [candidateDuration].
  ///
  /// The title and the credit must both agree after normalization. Not "be
  /// similar to" — agree. Edit distance was considered and rejected: the
  /// distance between `Heroes` and `Heroine`, or between two numbered parts of
  /// one suite, is exactly the distance between two spellings of a single
  /// title, and a threshold that admits the second admits the first.
  ///
  /// The duration then decides between [LyricsMatch.timed] and
  /// [LyricsMatch.plainOnly]; see those.
  LyricsMatch verdictFor({
    required String candidateTitle,
    required String candidateArtist,
    Duration? candidateDuration,
  }) {
    if (!comparableTitles.contains(normalizeForComparison(candidateTitle))) {
      return LyricsMatch.rejected;
    }
    if (!comparableArtists
        .contains(normalizeArtistForComparison(candidateArtist))) {
      return LyricsMatch.rejected;
    }
    if (duration == null || candidateDuration == null) {
      return LyricsMatch.plainOnly;
    }
    return durationsAgree(duration, candidateDuration)
        ? LyricsMatch.timed
        : LyricsMatch.rejected;
  }

  @override
  String toString() =>
      'LyricsQuery($artist — $title, ${duration?.inSeconds ?? '?'}s)';
}

/// Whether [wanted] and [candidate] are the same recording's running time.
///
/// `false` when either is unknown. Absence is not agreement: a candidate whose
/// duration nobody recorded has told us nothing, and treating silence as a
/// match is how a compilation's four-minute edit ends up wearing the album
/// cut's lyric. Callers that want to distinguish "disagrees" from "cannot
/// tell" ask [LyricsQuery.verdictFor] instead.
bool durationsAgree(
  Duration? wanted,
  Duration? candidate, {
  Duration tolerance = kDurationTolerance,
}) {
  if (wanted == null || candidate == null) return false;
  return (wanted - candidate).abs() <= tolerance;
}

/// How well a lyric document answers the question, higher being better.
///
/// The SDK is explicit that plain text, synced lines and word timing are three
/// independent facts rather than three rungs of a ladder — a document may carry
/// any combination. This ranking is not a claim about the model; it is this
/// plugin's preference order for choosing between two documents that are both
/// about the right recording, and it reads the way a listener would rank them:
/// karaoke beats a scrolling lyric beats a wall of text.
///
/// `0` means the document carries nothing usable, which is how an instrumental
/// record and a malformed payload both come out.
int lyricsRank(SwayveLyrics lyrics) {
  if (lyrics.hasWordTiming) return 3;
  if (lyrics.isSynced) return 2;
  if (lyrics.plain != null && lyrics.plain!.trim().isNotEmpty) return 1;
  return 0;
}
