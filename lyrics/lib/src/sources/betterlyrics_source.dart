/// BetterLyrics, this plugin's only source of word-level timing.
///
/// ## What the service actually does, as opposed to what was expected of it
///
/// This source was specified as a JSON word-array API. It is not one, and
/// everything below is written to what the live endpoint returned in August
/// 2026 rather than to the specification. Three findings, all measured:
///
/// **The parameter names are `s` and `a`.** The service publishes them at its
/// own root document: `s`/`song`/`songName` and `a`/`artist`/`artistName` are
/// required, `al`/`album`/`albumName` and `d`/`duration` are optional and
/// described there as improving the match. This sends the short forms, and all
/// four whenever the track carries them, because the service's matching is its
/// own and the more it is given the less this plugin has to second-guess it.
///
/// **The answer is TTML, not JSON words.** `{"ttml": "<tt …>…</tt>"}` — one
/// string field holding an Apple Music word-timed TTML document. See
/// `parsing/ttml_parser.dart`, which is written to it. The service's
/// `/ttml/getLyrics` route returns the same document under the key `lyrics`
/// instead, so both keys are read here: it costs one line and it means a
/// service that consolidates its routes does not silently stop working.
///
/// **Anonymous callers get the cache, and only the cache.** A query the service
/// has not answered recently comes back `401` with
/// `{"error": "API key required", "message": "Uncached queries require a valid
/// API key via X-API-Key header"}`. A cached one comes back `200` with
/// `x-auth-mode: cache` and `x-cache-status: HIT`. This plugin holds no key and
/// asks for none — a first-party plugin that shipped a credential would be
/// shipping a shared secret to every device — so `401` is read here as "this
/// service has nothing for you", which is exactly what it means for a caller in
/// this position. It is emphatically *not* read as an authentication failure:
/// there is no sign-in that would fix it, and reporting one would send a
/// listener looking for a setting that does not exist.
///
/// The practical consequence is that BetterLyrics answers for popular
/// recordings and declines for everything else, and LRCLIB is what carries the
/// rest of the library. That is a reasonable division and it is why the
/// provider asks both.
///
/// ## What can and cannot be checked
///
/// The document carries no title and no credit — the service does its matching
/// and does not say what it matched. So the usual title-and-credit check has
/// nothing to work on. What the document does carry is `<body dur="…">`, the
/// recording's running time, and that is checked hard: 3:21.570 against a
/// 200-second track is a match, and anything outside [kDurationTolerance] is
/// refused outright rather than downgraded.
///
/// When one of the two durations is missing the answer is taken on trust, and
/// that is the one place in this plugin where a match is believed rather than
/// verified. It is defensible only because of what was sent: the service was
/// given the title, the credit, the album and the duration, and it declined to
/// answer for everything it could not place. Believing a service's own matcher
/// when it has been given everything is a different act from guessing.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../lyrics_client.dart';
import '../matching.dart';
import '../parsing/lrc_parser.dart';
import '../parsing/ttml_parser.dart';
import 'lyrics_source.dart';

/// The BetterLyrics source.
final class BetterLyricsSource implements LyricsSource {
  /// Creates the source over [client].
  const BetterLyricsSource({required LyricsClient client}) : _client = client;

  final LyricsClient _client;

  @override
  String get name => kBetterLyricsSource;

  @override
  Future<SourceAttempt> lookUp(
    LyricsQuery query, {
    SwayveCancellationToken? cancel,
  }) async {
    try {
      final SwayveHttpResponse response = await _client.get(
        kBetterLyricsEndpoint,
        <String, String?>{
          's': query.title,
          'a': query.artist,
          'al': query.album,
          'd': query.duration == null
              ? null
              : '${query.duration!.inMilliseconds ~/ 1000}',
        },
        cancel: cancel,
      );

      // The three ways this service says no. `401` is the common one and is
      // explained at length above; `404` and `422` are a miss and a rejected
      // query, and a query this plugin built badly is still a recording it has
      // no lyric for.
      if (response.statusCode == 401 ||
          response.statusCode == 404 ||
          response.statusCode == 422) {
        return SourceAttempt.none;
      }
      // `503` with `{"error": "Service running in cache-only mode…"}` is what
      // the sibling providers answer when their upstream is unavailable. That
      // is a service problem rather than a missing lyric, so it goes through
      // `throwForStatus` and comes back as a failure — which the provider will
      // discard the moment LRCLIB manages an honest answer.
      if (!response.isSuccess) {
        throwForStatus(response, kBetterLyricsEndpoint, name);
      }

      final Object? body = response.bodyAsJson;
      if (body is! Map<String, Object?>) return SourceAttempt.none;

      final Object? document = body['ttml'] ?? body['lyrics'];
      if (document is! String || document.trim().isEmpty) {
        return SourceAttempt.none;
      }

      final ParsedTtml parsed = parseTtml(document);
      if (parsed.isEmpty) return SourceAttempt.none;

      // The only independent check available. Refused rather than downgraded:
      // a document whose running time disagrees is not a different edit of the
      // same performance, it is the service having matched something else.
      if (query.duration != null &&
          parsed.duration != null &&
          !durationsAgree(query.duration, parsed.duration)) {
        return SourceAttempt.none;
      }

      final SwayveLyrics lyrics = SwayveLyrics(
        // Filled in from the same lines rather than left null, because the SDK
        // asks a provider holding one form to publish the others: a host with
        // no karaoke view, or a listener who just wants to read the words,
        // must not come away empty because the timing was too good.
        plain: plainFromLines(parsed.lines),
        synced: parsed.lines,
        words: parsed.words,
        source: name,
      );
      return lyricsRank(lyrics) == 0
          ? SourceAttempt.none
          : SourceAttempt.found(lyrics);
    } on SwayvePluginCancelledException {
      rethrow;
    } on SwayvePluginException catch (error) {
      return SourceAttempt.failed(error);
    }
  }
}
