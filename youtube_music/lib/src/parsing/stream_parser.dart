/// Reading a player response into the audio streams a host can play.
///
/// Kept apart from `YouTubeMusicStreamProvider` for the same reason the other
/// parsers are kept apart from their providers: this half is a pure function
/// over decoded JSON, so the whole of it can be tested against captured
/// responses without a network, a host, or a plugin instance.
///
/// ## What it refuses to guess
///
/// A player response can say four quite different things, and telling them
/// apart is most of this file's job:
///
/// * here are your streams — the ordinary case;
/// * this video is gone, private or blocked where you are — a fact about *one*
///   song, which should drop that song and leave the rest of a queue alone;
/// * prove you are not a robot — a fact about *this session*, which is
///   recoverable by minting a new visitor identity and asking again;
/// * here is a video with no downloadable renditions at all — a fact about the
///   whole *approach*, which means the client this plugin asks as has been
///   closed and the embedded player is now the only way to play anything.
///
/// The last one is the one worth naming precisely. It looks like success —
/// status `OK`, a formats array with entries in it — and every entry carries a
/// streaming address the host cannot use. Reported as "unavailable" alongside
/// the ordinary failures it would be indistinguishable from a bad night on the
/// network, and nobody would ever find out the plugin had stopped working.
library;

import '../config.dart';
import '../json_path.dart';

/// One audio-only rendition of a track.
final class YouTubeAudioStream {
  /// Creates a stream description.
  const YouTubeAudioStream({
    required this.itag,
    required this.url,
    required this.mimeType,
    this.bitrate,
    this.contentLength,
    this.sampleRate,
    this.channels,
  });

  /// YouTube's own format number. Carried because format selection is written
  /// against it — see [preferredAudio].
  final int itag;

  /// Where the bytes are. Already signed; nothing has to be added to it.
  final Uri url;

  /// The full `mimeType` as reported, codecs parameter included.
  final String mimeType;

  /// Average bits per second, when stated.
  final int? bitrate;

  /// The exact size of the whole stream in bytes, when stated.
  ///
  /// Worth carrying even though nothing plays it back: it is what lets a host
  /// say how large a download will be before starting one.
  final int? contentLength;

  final int? sampleRate;
  final int? channels;

  /// The container half of [mimeType], with the codecs parameter dropped.
  ///
  /// `audio/mp4` or `audio/webm`. What a host would put in a `Content-Type`
  /// or use to pick a decoder.
  String get container {
    final int semicolon = mimeType.indexOf(';');
    return (semicolon == -1 ? mimeType : mimeType.substring(0, semicolon))
        .trim();
  }

  /// Whether this rendition is one every platform can decode.
  ///
  /// AAC in an MP4 container. The alternative YouTube offers is Opus in WebM,
  /// which Android plays natively and Apple's media stack does not play at
  /// all — so "universal" here is a real distinction rather than a preference,
  /// and it is why [preferredAudio] takes a capability rather than a taste.
  bool get isUniversal => container == 'audio/mp4';

  @override
  String toString() => 'YouTubeAudioStream(itag $itag, $mimeType)';
}

/// Everything a player response said, once it has been believed.
final class YouTubePlayerStreams {
  /// Creates a parsed player response.
  const YouTubePlayerStreams({
    required this.audio,
    required this.expiresIn,
    this.duration,
  });

  /// Every audio-only rendition, in the order YouTube listed them.
  final List<YouTubeAudioStream> audio;

  /// How long these addresses stay good for.
  final Duration expiresIn;

  /// How long the recording runs, as the player response states it.
  ///
  /// The one exact figure in this whole area, and the reason it is carried:
  /// every other length this plugin knows is read off a line of display text —
  /// `Artist • Album • 3:16` — which is rounded at best and describes a
  /// different upload of the same song at worst. This is the length of the
  /// audio the addresses above actually point at.
  ///
  /// Null when the response did not say, which is not something to fail over.
  final Duration? duration;

  /// The best rendition for a host with the given capability.
  ///
  /// [preferUniversal] is true when the host cannot be relied on to decode
  /// Opus in WebM — which today means every Apple platform. The choice is
  /// between "the best available" and "the best that will actually play", and
  /// only the host knows which of those it is asking for.
  ///
  /// Within a container, highest bitrate wins. A music player's default should
  /// be the best rendition on offer; a host that wants less can say so with
  /// [maxBitrateKbps].
  YouTubeAudioStream? preferredAudio({
    required bool preferUniversal,
    int? maxBitrateKbps,
  }) {
    final int? ceiling = maxBitrateKbps == null ? null : maxBitrateKbps * 1000;

    bool withinCeiling(YouTubeAudioStream s) =>
        ceiling == null || s.bitrate == null || s.bitrate! <= ceiling;

    YouTubeAudioStream? best(Iterable<YouTubeAudioStream> from) {
      YouTubeAudioStream? winner;
      for (final YouTubeAudioStream stream in from) {
        if (winner == null || (stream.bitrate ?? 0) > (winner.bitrate ?? 0)) {
          winner = stream;
        }
      }
      return winner;
    }

    final Iterable<YouTubeAudioStream> allowed = audio.where(withinCeiling);
    final YouTubeAudioStream? universal =
        best(allowed.where((YouTubeAudioStream s) => s.isUniversal));
    if (preferUniversal) {
      // Falling back past the ceiling before falling back past the codec: a
      // rendition the host cannot decode is not a lower-quality answer, it is
      // no answer. Only if there is no MP4 at all does this hand back
      // something the host may refuse — which is still better than refusing on
      // its behalf.
      return universal ??
          best(audio.where((YouTubeAudioStream s) => s.isUniversal)) ??
          best(allowed) ??
          best(audio);
    }
    return best(allowed) ?? universal ?? best(audio);
  }
}

/// Why a player response could not be turned into streams.
enum YouTubeStreamRefusal {
  /// This one item is gone, private, age-restricted or blocked here. A fact
  /// about the song.
  itemUnavailable,

  /// The session has been refused. A fact about this plugin instance, and
  /// recoverable: mint a new visitor identity and ask once more.
  sessionRefused,

  /// The response was fine and carried no address anybody could fetch. A fact
  /// about the *approach* — the client this plugin asks as has been closed.
  extractionClosed,
}

/// Raised by [parsePlayerResponse] instead of returning streams.
///
/// Carries both the machine-readable [reason] and the sentence a person should
/// read, because the caller does different things with each: the reason
/// decides whether to retry, drop the track or fall back to the embed, and the
/// message is what ends up in front of somebody.
final class YouTubeStreamException implements Exception {
  /// Creates a refusal.
  const YouTubeStreamException(this.reason, this.message);

  final YouTubeStreamRefusal reason;
  final String message;

  @override
  String toString() => message;
}

/// Reads [response] into the streams it describes.
///
/// Throws [YouTubeStreamException] rather than a `SwayvePluginException`,
/// because the two possible recoveries — retry with a new identity, or fall
/// back to the embedded player — are decisions for the provider, and a
/// response that has already been turned into the SDK's vocabulary has thrown
/// that choice away.
YouTubePlayerStreams parsePlayerResponse(Map<String, Object?> response) {
  final String status =
      stringAt(response, const <Object>['playabilityStatus', 'status']) ?? '';
  final String reason =
      stringAt(response, const <Object>['playabilityStatus', 'reason']) ?? '';

  if (status == 'LOGIN_REQUIRED') {
    throw YouTubeStreamException(
      YouTubeStreamRefusal.sessionRefused,
      reason.isEmpty
          ? 'YouTube would not answer without a signed-in session.'
          : 'YouTube answered: $reason',
    );
  }
  if (status.isNotEmpty && status != 'OK') {
    throw YouTubeStreamException(
      YouTubeStreamRefusal.itemUnavailable,
      reason.isEmpty
          ? 'This track is not available on YouTube Music right now.'
          : reason,
    );
  }

  final List<Object?> formats = listAt(response, const <Object>[
    'streamingData',
    'adaptiveFormats',
  ]);

  final List<YouTubeAudioStream> audio = <YouTubeAudioStream>[];
  final Set<int> seen = <int>{};
  for (final Object? entry in formats) {
    final Map<String, Object?> format = mapOf(entry);
    final String? mimeType = stringAt(format, const <Object>['mimeType']);
    if (mimeType == null || !mimeType.startsWith('audio/')) continue;

    final String? url = stringAt(format, const <Object>['url']);
    if (url == null || url.isEmpty) continue;
    final Uri? parsed = Uri.tryParse(url);
    if (parsed == null || !isAllowedHost(parsed.host)) {
      // Unreachable with the manifest as written, and here so that YouTube
      // moving its media servers to a host this plugin never declared fails
      // loudly rather than quietly handing the host an undeclared destination.
      continue;
    }

    final int? itag = intAt(format, const <Object>['itag']);
    if (itag == null) continue;
    // The same itag can appear twice — once plain and once with loudness
    // normalisation applied. The first is the one YouTube ranked higher.
    if (!seen.add(itag)) continue;

    audio.add(
      YouTubeAudioStream(
        itag: itag,
        url: parsed,
        mimeType: mimeType,
        bitrate: intAt(format, const <Object>['bitrate']) ??
            intAt(format, const <Object>['averageBitrate']),
        // Sent as a string, because it routinely exceeds what JSON numbers are
        // safely exact to.
        contentLength: int.tryParse(
          stringAt(format, const <Object>['contentLength']) ?? '',
        ),
        sampleRate: int.tryParse(
          stringAt(format, const <Object>['audioSampleRate']) ?? '',
        ),
        channels: intAt(format, const <Object>['audioChannels']),
      ),
    );
  }

  if (audio.isEmpty) {
    throw const YouTubeStreamException(
      YouTubeStreamRefusal.extractionClosed,
      'YouTube returned no audio this player can fetch. It has most likely '
      'stopped serving plain media addresses to the client this plugin asks '
      'as, which means playback has to go through the embedded player.',
    );
  }

  return YouTubePlayerStreams(
    audio: audio,
    expiresIn: _expiry(response),
    duration: _statedDuration(response),
  );
}

/// The recording's length, as `videoDetails` states it.
///
/// Whole seconds, which is what the field carries. Null for anything missing,
/// unparseable or nonsensical — a live stream reports zero, and zero is not a
/// duration, it is the absence of one.
Duration? _statedDuration(Map<String, Object?> response) {
  final int? seconds = int.tryParse(
    stringAt(response, const <Object>['videoDetails', 'lengthSeconds']) ?? '',
  );
  if (seconds == null || seconds <= 0) return null;
  return Duration(seconds: seconds);
}

/// How long the addresses in [response] are good for.
///
/// The response's own figure, less a margin, and floored at zero so a stale
/// clock cannot produce a negative lifetime the host would read as "already
/// expired" and re-resolve forever.
Duration _expiry(Map<String, Object?> response) {
  final int? stated = int.tryParse(
    stringAt(response, const <Object>['streamingData', 'expiresInSeconds']) ??
        '',
  );
  final Duration lifetime =
      stated == null ? kStreamLifetime : Duration(seconds: stated);
  final Duration withMargin = lifetime - kStreamExpiryMargin;
  return withMargin.isNegative ? Duration.zero : withMargin;
}
