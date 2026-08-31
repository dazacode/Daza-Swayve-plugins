import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../innertube_client.dart';
import '../json_path.dart';
import '../parsing/caption_parser.dart';

/// YouTube Music's answer to `SwayveLyricsProvider`. Capability: `lyrics`.
///
/// ## Why this reads captions and not YouTube Music's own lyrics page
///
/// Because that page is empty. A `next` response's second tab is "Lyrics" and
/// it carries a browse id of the form `MPLY…`, which looks exactly like the
/// door to what this provider wants. Measured against the live endpoint: that
/// tab arrives marked `unselectable: true`, and browsing the id anyway
/// answers with a one-kilobyte `messageRenderer` reading "Lyrics not
/// available" — not for one obscure recording, but for the most-watched music
/// video on the service. There is no licensed lyric behind it for an
/// anonymous session, and there is nothing this plugin can do to obtain one.
///
/// A caption track is a different thing that is very often the same text. The
/// player response for a music upload carries one, timed to the recording,
/// and for an official upload it is usually the lyric written out. So that is
/// what this returns — **labelled as what it is**. [SwayveLyrics.source] says
/// "YouTube captions" rather than "YouTube Music", because a host may show
/// the attribution and a listener reading a machine transcript deserves to
/// know that is what they are reading.
///
/// ## Why it asks more than once
///
/// Which clients the player endpoint answers for changes, and it changes
/// without an announcement. The failure mode that matters here is not an
/// error — it is silence: a client that stops carrying a `captions` block
/// makes every track look like a track with no lyrics, which is what most
/// tracks genuinely are, so nothing anywhere reports a problem. So this walks
/// [kCaptionsClients] in order and only gives up once all of them have come
/// back without captions. See that list for what is in it and why it is
/// ordered the way it is.
///
/// ## Line-level, and no word timing
///
/// A caption cue is a line with a start and a duration. It says nothing about
/// where one word ends and the next begins, so [SwayveLyrics.words] is left
/// null rather than filled with a guess: the SDK treats "this provider does
/// not do word timing" and "this lyric has no words" as different claims, and
/// only the first is true here.
///
/// ## Absent is normal
///
/// Most recordings have no caption track, and this returns `null` for them.
/// That is the SDK's "none found", not an error, and a host must be able to
/// ask for a hundred tracks' lyrics and be told no a hundred times without
/// anything being reported as broken.
final class YouTubeMusicLyricsProvider implements SwayveLyricsProvider {
  /// Creates a provider over [client].
  YouTubeMusicLyricsProvider({
    required InnerTubeClient client,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  }) : _client = client;

  final InnerTubeClient _client;

  /// The deadlines this provider works to.
  final YouTubeMusicTimeouts timeouts;

  /// The attribution every lyric from this provider carries.
  static const String source = 'YouTube captions';

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
          // The SDK widened this method to take a whole track precisely
          // because a lyrics provider is usually not the track's own source
          // and has nothing to look an opaque id up by. This provider *is*
          // the source, so it reads the id and ignores the rest — and it
          // still has to check the id is one of its own, because the host may
          // offer this plugin a track another one published.
          if (!YouTubeMusicIds.isKind(track.id, YouTubeMusicIdKind.track)) {
            return null;
          }

          final Uri? url = await _captionUrl(track.id.value, cancel);
          if (url == null) return null;

          final List<SwayveLyricLine> lines = parseCaptionLines(
            await _client.getText(url, cancel: cancel),
          );
          if (lines.isEmpty) return null;

          return SwayveLyrics(
            plain: plainFromLines(lines),
            synced: lines,
            source: source,
            // Not claimed either way. The badge on the *track* says whether
            // the recording is explicit; a caption track carries no such
            // flag, and stamping one from the track's badge would be this
            // provider asserting something about text it did not inspect.
          );
        },
      );

  /// The caption track to read, asking each of [kCaptionsClients] in turn.
  ///
  /// Falls through on two things, and they are different failures wearing the
  /// same face: a response with no `captions` block at all, and one whose
  /// `playabilityStatus` is not `OK` — which is how a client that has been
  /// turned down actually answers ("The page needs to be reloaded"), rather
  /// than with an HTTP error the client layer would have raised.
  ///
  /// `null` after the last one, which remains the ordinary "this recording
  /// has no captions" answer rather than a failure. That does mean a genuine
  /// service-wide outage costs three requests before this says no — an
  /// acceptable price, since the alternative is one request that says no
  /// forever without anybody noticing. The whole walk shares one operation
  /// budget, and the visitor identity behind it is minted once and reused.
  Future<Uri?> _captionUrl(
    String videoId,
    SwayveCancellationToken? cancel,
  ) async {
    for (final YouTubeMusicClientIdentity client in kCaptionsClients) {
      cancel?.throwIfCancelled();
      final Map<String, Object?> player = await _client.captionsPlayer(
        videoId,
        client: client,
        cancel: cancel,
      );
      final String? status = stringAt(player, const <Object>[
        'playabilityStatus',
        'status',
      ]);
      if (status != null && status != 'OK') continue;
      final Uri? url = _captionUrlOf(player);
      if (url != null) return url;
    }
    return null;
  }

  /// The caption track to read, or `null` when the response carries none.
  ///
  /// The first track in the list, which is the service's own default: for a
  /// music upload it is the uploader's own caption file, and the
  /// auto-generated `asr` rendition comes after it. Preferring the host's
  /// language would sound like an improvement and is not — a translated
  /// caption track is a translation of the lyric, and a listener asking for
  /// the words of a song wants the words that were sung.
  Uri? _captionUrlOf(Map<String, Object?> player) {
    for (final Object? entry in listAt(player, const <Object>[
      'captions',
      'playerCaptionsTracklistRenderer',
      'captionTracks',
    ])) {
      final String? baseUrl = stringAt(entry, const <Object>['baseUrl']);
      if (baseUrl == null || baseUrl.isEmpty) continue;
      final Uri? parsed = Uri.tryParse(baseUrl);
      if (parsed == null || !parsed.hasScheme) continue;
      // The format parameter is stripped so the plain `<transcript>`
      // rendering comes back. Both formats parse — see
      // `parsing/caption_parser.dart` — so this is tidiness rather than a
      // requirement, and it keeps the URL identical to the one the player
      // response actually handed over.
      return captionUrl(parsed);
    }
    return null;
  }
}
