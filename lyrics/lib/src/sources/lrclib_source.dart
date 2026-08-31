/// LRCLIB, this plugin's primary source of synced lyrics.
///
/// LRCLIB is a free, keyless, CC0 database of user-submitted `.lrc` files. It
/// is the best answer available to "what are the words to this recording, timed
/// to it", it has no account and no quota, and its only stated condition is
/// that a client identify itself in its `User-Agent`. That is the whole reason
/// it is first here.
///
/// ## Two endpoints, and only one of them adjudicates
///
/// `GET /api/get` takes the recording — `track_name`, `artist_name`,
/// `album_name`, `duration` — and answers with one record or `404`. Measured
/// against the live service: it applies its own duration matching, and asking
/// for a 260-second "Blinding Lights" answers with a 261-second record rather
/// than with the 200-second album cut. It also answers `200` when `duration` is
/// omitted entirely, picking a record of its own choosing — which is the reason
/// nothing here treats a `200` as self-evidently correct. Every record is
/// checked against the track before it is believed, and the record carries the
/// four fields needed to do it (`trackName`, `artistName`, `albumName`,
/// `duration`).
///
/// `GET /api/search` takes a title and a credit and answers with up to twenty
/// candidates, adjudicating nothing. Observed for one query: five of the first
/// six results were the same lyric filed under five different compilation
/// albums, with running times of 202, 202, 202, 248 and 263 seconds. Three of
/// those are the right recording and two are not, and nothing but the duration
/// separates them. This is what [LyricsQuery.verdictFor] exists for.
///
/// ## What the record actually carries
///
/// `id`, `name`, `trackName`, `artistName`, `albumName`, `duration` (a JSON
/// number of seconds, fractional), `instrumental`, `plainLyrics`,
/// `syncedLyrics` and — newer than the brief this plugin was written to —
/// `lyricsfile`, a YAML rendering of the same lyric. `lyricsfile` is ignored:
/// it says nothing `syncedLyrics` does not, and parsing a second serialization
/// of the same data would be a second thing to keep working.
///
/// `instrumental: true` comes with both lyric fields `null`. That is a record
/// asserting the recording has no words, and it is returned as
/// [SourceAttempt.none] — an instrumental has no lyric, and saying so is not
/// the same as failing to find one.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../lyrics_client.dart';
import '../matching.dart';
import '../parsing/lrc_parser.dart';
import 'lyrics_source.dart';

/// The LRCLIB source.
final class LrcLibSource implements LyricsSource {
  /// Creates the source over [client].
  const LrcLibSource({required LyricsClient client}) : _client = client;

  final LyricsClient _client;

  @override
  String get name => kLrcLibSource;

  @override
  Future<SourceAttempt> lookUp(
    LyricsQuery query, {
    SwayveCancellationToken? cancel,
  }) async {
    try {
      final SourceAttempt exact = await _exact(query, cancel: cancel);
      if (exact.isFound) return exact;
      cancel?.throwIfCancelled();
      return await _search(query, cancel: cancel);
    } on SwayvePluginCancelledException {
      // Cancellation is the host's decision, not a fault of this service, and
      // it must not be swallowed into "no lyrics" — the provider has to stop
      // asking the next source too.
      rethrow;
    } on SwayvePluginException catch (error) {
      return SourceAttempt.failed(error);
    }
  }

  /// The exact-match endpoint.
  Future<SourceAttempt> _exact(
    LyricsQuery query, {
    SwayveCancellationToken? cancel,
  }) async {
    final SwayveHttpResponse response = await _client.get(
      kLrcLibGetEndpoint,
      <String, String?>{
        'track_name': query.title,
        'artist_name': query.artist,
        'album_name': query.album,
        // Whole seconds. LRCLIB's records carry a fractional duration and its
        // matching is tolerant, so rounding here loses nothing.
        'duration': query.duration == null
            ? null
            : '${query.duration!.inMilliseconds ~/ 1000}',
      },
      cancel: cancel,
    );

    // `TrackNotFound`. The ordinary answer, and the reason this method is not
    // allowed to treat a non-2xx status as a fault on its own.
    if (response.statusCode == 404) return SourceAttempt.none;
    if (!response.isSuccess) throwForStatus(response, kLrcLibGetEndpoint, name);

    final Object? body = response.bodyAsJson;
    if (body is! Map<String, Object?>) return SourceAttempt.none;
    return _attemptFor(query, body);
  }

  /// The search fallback, which this plugin has to adjudicate itself.
  Future<SourceAttempt> _search(
    LyricsQuery query, {
    SwayveCancellationToken? cancel,
  }) async {
    final SwayveHttpResponse response = await _client.get(
      kLrcLibSearchEndpoint,
      <String, String?>{
        'track_name': query.title,
        'artist_name': query.artist,
      },
      cancel: cancel,
    );

    if (response.statusCode == 404) return SourceAttempt.none;
    if (!response.isSuccess) {
      throwForStatus(response, kLrcLibSearchEndpoint, name);
    }

    final Object? body = response.bodyAsJson;
    if (body is! List<Object?>) return SourceAttempt.none;

    // Every candidate is scored and the best is taken, rather than the first
    // that passes. The list comes back in the service's own relevance order,
    // which is not the same question as "which of these is the recording being
    // played", and a synced record further down beats a plain one at the top.
    SwayveLyrics? best;
    for (final Object? entry in body) {
      cancel?.throwIfCancelled();
      if (entry is! Map<String, Object?>) continue;
      final SourceAttempt attempt = _attemptFor(query, entry);
      final SwayveLyrics? candidate = attempt.lyrics;
      if (candidate == null) continue;
      if (best == null || lyricsRank(candidate) > lyricsRank(best)) {
        best = candidate;
      }
      // Nothing ranks above word timing, so there is no reason to read the
      // rest of the page once one turns up. LRCLIB records do not carry it
      // today — enhanced LRC is rare — which is exactly why this is written as
      // a rule about ranks rather than an assumption about the format.
      if (lyricsRank(best) == 3) break;
    }
    return best == null ? SourceAttempt.none : SourceAttempt.found(best);
  }

  /// One LRCLIB record, checked against [query] and converted.
  SourceAttempt _attemptFor(LyricsQuery query, Map<String, Object?> record) {
    final String? title = _stringOr(record['trackName'], record['name']);
    final String? artist = record['artistName'] as String?;
    if (title == null || artist == null) return SourceAttempt.none;

    final LyricsMatch match = query.verdictFor(
      candidateTitle: title,
      candidateArtist: artist,
      candidateDuration: _durationOf(record['duration']),
    );
    if (match == LyricsMatch.rejected) return SourceAttempt.none;

    // An instrumental is a record saying there is nothing to show, which is
    // information rather than a miss — but it reaches the host the same way a
    // miss does, because `SwayveLyrics` has no way to say "this recording has
    // no words" that is different from having none.
    if (record['instrumental'] == true) return SourceAttempt.none;

    final String? syncedText = record['syncedLyrics'] as String?;
    final ParsedLrc parsed =
        syncedText == null ? ParsedLrc.empty : parseLrc(syncedText);
    final String? plainText = (record['plainLyrics'] as String?)?.trim();

    final SwayveLyrics lyrics = SwayveLyrics(
      // The service's own plain rendering when it has one, and the synced lines
      // flattened when it does not. Preferring the service's is not just
      // tidiness: its plain text keeps the paragraph breaks between verses,
      // which the timed form spends on instrumental gaps instead.
      plain: plainText != null && plainText.isNotEmpty
          ? plainText
          : plainFromLines(parsed.lines),
      synced: parsed.lines.isEmpty ? null : parsed.lines,
      words: parsed.words,
      source: name,
      // Not claimed either way. LRCLIB records carry no explicit-content flag,
      // and inferring one from the track's own badge would be this plugin
      // asserting something about text it did not inspect.
    );

    final SwayveLyrics? permitted = asPermittedBy(match, lyrics);
    return permitted == null
        ? SourceAttempt.none
        : SourceAttempt.found(permitted);
  }

  static String? _stringOr(Object? first, Object? second) {
    if (first is String && first.trim().isNotEmpty) return first;
    if (second is String && second.trim().isNotEmpty) return second;
    return null;
  }

  /// A record's `duration`, which arrives as a fractional number of seconds.
  static Duration? _durationOf(Object? value) {
    final double? seconds = switch (value) {
      final num number => number.toDouble(),
      final String text => double.tryParse(text),
      _ => null,
    };
    if (seconds == null || !seconds.isFinite || seconds <= 0) return null;
    return Duration(milliseconds: (seconds * 1000).round());
  }
}
