/// What a lyric service looks like from inside this plugin.
///
/// ## Why "no lyrics" and "broken" have to stay apart
///
/// A lyrics provider says no far more often than it says yes, and that is
/// normal rather than a fault: most recordings in a real library — album
/// tracks, instrumentals, live takes, a friend's SoundCloud upload — have never
/// been transcribed by anybody. The SDK's answer for that is `null`, and a host
/// is built to ask a hundred times and be told no a hundred times without
/// anything being reported as degraded.
///
/// The trouble is that a service which is *down* also produces no lyrics, and
/// if the two look the same from here then a total outage is indistinguishable
/// from a quiet afternoon. Nobody would ever notice; the plugin would simply
/// stop working and go on reporting that everything was fine.
///
/// So a source answers with a [SourceAttempt] rather than with a nullable
/// document, and the three cases it can report are kept separate all the way up
/// to the provider:
///
/// * [SourceAttempt.found] — a document, and how far it may be trusted;
/// * [SourceAttempt.none] — asked and answered; this service does not have it;
/// * [SourceAttempt.failed] — could not ask, or could not read the answer.
///
/// The provider then applies the rule that follows from the distinction: it
/// returns the best document any source found; failing that it returns `null`
/// if *any* source got as far as an honest "no"; and only when **every** source
/// failed does it rethrow, because that is the only situation in which nothing
/// was actually learned. See `providers/lyrics_provider.dart`.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../matching.dart';

/// The outcome of asking one service about one recording.
final class SourceAttempt {
  const SourceAttempt._({this.lyrics, this.failure});

  /// A document this source stands behind.
  ///
  /// [lyrics] has already been trimmed to what the match justifies: a source
  /// whose candidate matched only as [LyricsMatch.plainOnly] returns a document
  /// carrying plain text and no timings, rather than returning the timings and
  /// leaving the caller to remember not to use them.
  factory SourceAttempt.found(SwayveLyrics lyrics) =>
      SourceAttempt._(lyrics: lyrics);

  /// This service answered, and does not have this recording.
  static const SourceAttempt none = SourceAttempt._();

  /// This service could not be asked, or answered something unusable.
  ///
  /// [failure] is carried rather than thrown so that one service being down
  /// does not stop the others being asked. It is rethrown by the provider only
  /// if nothing else got anywhere.
  factory SourceAttempt.failed(SwayvePluginException failure) =>
      SourceAttempt._(failure: failure);

  /// The document, when one was found.
  final SwayveLyrics? lyrics;

  /// The failure, when there was one.
  final SwayvePluginException? failure;

  /// Whether this attempt found something.
  bool get isFound => lyrics != null;

  /// Whether this attempt failed, as opposed to answering "not here".
  bool get isFailure => failure != null;

  @override
  String toString() => switch ((lyrics, failure)) {
        (final SwayveLyrics found, _) => 'SourceAttempt.found($found)',
        (_, final SwayvePluginException error) =>
          'SourceAttempt.failed($error)',
        _ => 'SourceAttempt.none',
      };
}

/// One lyric service.
///
/// Implementations make exactly one logical lookup per call, honour [cancel]
/// throughout, and never throw: a failure comes back as
/// [SourceAttempt.failed]. The provider owns the deadline and the ordering.
abstract interface class LyricsSource {
  /// What this source is called, as it will appear in [SwayveLyrics.source].
  String get name;

  /// Looks [query] up.
  Future<SourceAttempt> lookUp(
    LyricsQuery query, {
    SwayveCancellationToken? cancel,
  });
}

/// [lyrics] reduced to what [match] justifies publishing.
///
/// The one place the [LyricsMatch.plainOnly] rule is applied, so that both
/// sources obey it identically: a candidate whose *cut* could not be confirmed
/// keeps its words and loses its timings. See [LyricsMatch.plainOnly] for why
/// that is the right trade rather than a cautious one.
///
/// Returns `null` when nothing usable survives, which is what an instrumental
/// record and a synced-only document that failed the duration check both come
/// to.
SwayveLyrics? asPermittedBy(LyricsMatch match, SwayveLyrics lyrics) {
  switch (match) {
    case LyricsMatch.rejected:
      return null;
    case LyricsMatch.timed:
      return lyricsRank(lyrics) == 0 ? null : lyrics;
    case LyricsMatch.plainOnly:
      final String? plain = lyrics.plain;
      if (plain == null || plain.trim().isEmpty) return null;
      return SwayveLyrics(
        plain: plain,
        source: lyrics.source,
        explicitContent: lyrics.explicitContent,
      );
  }
}
