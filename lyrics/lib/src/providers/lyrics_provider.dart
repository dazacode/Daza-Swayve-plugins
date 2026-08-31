/// The plugin's one provider. Capability: `lyrics`.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../matching.dart';
import '../sources/lyrics_source.dart';

/// Lyrics for a recording that came from somewhere else.
///
/// ## Why this plugin exists at all
///
/// The SDK widened `SwayveLyricsProvider.lyrics` to take a whole
/// [SwayveTrack] rather than a [SwayveMediaId], and that widening is this
/// plugin's entire reason to be. A media id is opaque by design: an id minted
/// by the YouTube Music plugin means nothing to anybody else, and a second
/// plugin picking it apart would be exactly the provider-specific knowledge the
/// SDK keeps out of everything. A whole track is different. It carries the
/// title, the credit, the release and the running time — enough to find a
/// recording in somebody else's catalogue, and, just as importantly, enough to
/// decide the match is not good enough.
///
/// So this provider serves tracks it did not publish and knows nothing about.
/// A song playing from YouTube Music, a set from SoundCloud, a file out of a
/// listener's own iBroadcast library: all three arrive here as a
/// [SwayveTrack], and all three are looked up the same way. There is no
/// `if (plugin.id == …)` anywhere in it, and there is no id parsing.
///
/// ## The order the sources are asked in
///
/// Word-level beats synced beats plain — [lyricsRank] — so BetterLyrics is
/// asked first, because it is the only source that has word timing, and a
/// word-timed answer ends the lookup immediately. When it declines, which for
/// anything outside its anonymous cache it usually will, LRCLIB is asked and
/// its answer is kept.
///
/// That is at most two requests and usually two, which is the right shape: the
/// alternative orderings all cost the same two requests in the common case and
/// lose the chance of stopping after one.
///
/// ## Saying no, and the difference between the two ways of saying it
///
/// `null` is the ordinary answer. Most recordings have no lyric anywhere, and a
/// host must be able to ask about a hundred tracks and be told no a hundred
/// times without anything being reported as broken. So a miss is not an error
/// and nothing here throws for one.
///
/// A rethrow happens in exactly one situation: **every** source failed, and
/// none of them got as far as an honest "not here". That is the only case in
/// which nothing was learned, and it is the case a host needs to hear about,
/// because it is what a total outage looks like. One source failing while the
/// other answers is not reported at all — the listener got their lyric, and
/// there is nothing for them to do about it.
final class LyricsProvider implements SwayveLyricsProvider {
  /// Creates a provider over [sources], asked in the order given.
  LyricsProvider({
    required this.sources,
    this.timeouts = LyricsTimeouts.manifest,
  });

  /// The services this provider asks, best-first.
  final List<LyricsSource> sources;

  /// The deadlines this provider works to.
  ///
  /// [LyricsTimeouts.operation] covers the whole call, every source included —
  /// a lookup does not get a fresh budget per service.
  final LyricsTimeouts timeouts;

  @override
  Future<SwayveLyrics?> lyrics(
    SwayveTrack track, {
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'lyrics',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          // A track with no title, or with nothing credited on it, cannot be
          // looked up without guessing — see `LyricsQuery.fromTrack`. It costs
          // no request to notice that.
          final LyricsQuery? query = LyricsQuery.fromTrack(track);
          if (query == null) return null;

          SwayveLyrics? best;
          SwayvePluginException? firstFailure;
          var answered = false;

          for (final LyricsSource source in sources) {
            cancel?.throwIfCancelled();
            final SourceAttempt attempt =
                await source.lookUp(query, cancel: cancel);

            if (attempt.isFailure) {
              firstFailure ??= attempt.failure;
              continue;
            }
            answered = true;

            final SwayveLyrics? found = attempt.lyrics;
            if (found == null) continue;
            if (best == null || lyricsRank(found) > lyricsRank(best)) {
              best = found;
            }
            // Nothing outranks word timing, so there is no reason to keep
            // asking. This is written against the rank rather than against the
            // source's name so that adding a source cannot quietly change
            // which one wins.
            if (lyricsRank(best) == 3) break;
          }

          if (best != null) return best;
          // Nothing found. If at least one service managed to say so, that is
          // the answer; if none did, nothing was learned and the host is told.
          if (!answered && firstFailure != null) throw firstFailure;
          return null;
        },
      );
}
