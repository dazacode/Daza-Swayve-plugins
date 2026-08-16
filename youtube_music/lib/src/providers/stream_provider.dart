import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../embed_document.dart';
import '../errors.dart';
import '../ids.dart';
import '../innertube_client.dart';
import '../parsing/stream_parser.dart';

/// YouTube Music's answer to `SwayveStreamProvider`. Capability: `streaming`.
///
/// ## Two answers, and which one the host gets
///
/// A track resolves to one of two things, and the host chooses which by the
/// hints it sends:
///
/// * **audio** (`preferAudioOnly`, no embed allowed) — a direct media address
///   for an audio-only rendition, which the host's own engine plays and can
///   keep on the device;
/// * **video** (`preferAudioOnly: false`, embed allowed) — the embedded player
///   page, which the host renders and which is a music video rather than a
///   sound file.
///
/// That is exactly the distinction `SwayvePlaybackHints` was designed to
/// express, and it is why one provider serves both surfaces without the host
/// learning which service is behind either.
///
/// ## The extraction, and the decision behind it
///
/// **This reverses an earlier decision in this file, deliberately.** The
/// previous version returned only an embed, on the reasoning that extracting a
/// media address means reproducing the signature logic of a player the service
/// controls — logic that breaks whenever that player changes — and that doing
/// so takes the plugin somewhere the service has not invited it.
///
/// The first half of that no longer describes what happens here. The client
/// this plugin now asks the player endpoint as returns addresses that are
/// **already signed**: there is no cipher to solve, no throttling parameter to
/// unscramble, and no JavaScript to execute. See [kPlayerClientName]. What
/// broke every previous approach is not part of this one.
///
/// The second half stands unchanged, and is a policy decision rather than a
/// technical one: fetching media directly is contrary to YouTube's terms, and
/// `media.downloadable` in the manifest was a considered commitment to the
/// SDK's rule that streamable must never imply downloadable. Both were changed
/// on purpose, by the person who owns this plugin, and this comment exists so
/// that the next reader knows it was a choice rather than an oversight.
///
/// ## Why the embed survives
///
/// Not as a courtesy. The client above is the last one YouTube serves plain
/// addresses to, and the ones before it — `ANDROID`, `IOS`, `ANDROID_VR` —
/// were closed one after another. When this one closes, [resolvePlayback]
/// hands back the embedded player instead of failing, so the plugin degrades
/// to exactly what it used to be rather than stopping.
final class YouTubeMusicStreamProvider implements SwayveStreamProvider {
  /// Creates a provider for [host], resolving through [client].
  YouTubeMusicStreamProvider({
    required SwayveHostInfo host,
    required InnerTubeClient client,
    SwayvePluginLogger? log,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  })  : _host = host,
        _client = client,
        _log = log;

  final SwayveHostInfo _host;
  final InnerTubeClient _client;
  final SwayvePluginLogger? _log;

  /// The deadlines this provider works to.
  final YouTubeMusicTimeouts timeouts;

  /// Embed kinds in the order this plugin would rather have them.
  ///
  /// An in-app web view is preferred because it gives the host a surface it
  /// owns — sizing, lifecycle, and teardown when playback stops.
  static const List<SwayveWebEmbedKind> preferredEmbedKinds =
      <SwayveWebEmbedKind>[
    SwayveWebEmbedKind.inAppWebView,
    SwayveWebEmbedKind.iframe,
  ];

  /// The controls the host may drive on the returned embed.
  ///
  /// These are the operations the embedded player's own JavaScript API
  /// exposes once `enablejsapi` is set, which is why the URL sets it. Listing
  /// a control the host cannot actually drive would be worse than listing
  /// none: the SDK says an absent control must be disabled in the UI, so an
  /// over-claim becomes a button that does nothing.
  static const Set<SwayveEmbedControl> embedControls = <SwayveEmbedControl>{
    SwayveEmbedControl.play,
    SwayveEmbedControl.pause,
    SwayveEmbedControl.seek,
    SwayveEmbedControl.volume,
    SwayveEmbedControl.positionUpdates,
  };

  /// The embedded-player URL for [videoId].
  static Uri embedUri(String videoId) => Uri.https(
        'www.youtube.com',
        '/embed/$videoId',
        const <String, String>{
          // Required for the host to drive the controls listed above.
          'enablejsapi': '1',
          // Play in place on mobile instead of taking over the screen.
          'playsinline': '1',
          // No end-screen suggestions from unrelated channels.
          'rel': '0',
        },
      );

  @override
  Future<SwayvePlayableSource> resolvePlayback(
    SwayveMediaId id, {
    SwayvePlaybackHints hints = SwayvePlaybackHints.defaults,
    SwayveCancellationToken? cancel,
  }) =>
      runGuarded(
        'resolvePlayback',
        timeout: timeouts.operation,
        cancel: cancel,
        body: () async {
          if (!YouTubeMusicIds.isKind(id, YouTubeMusicIdKind.track)) {
            throw SwayvePluginUnsupportedException(
              'YouTube Music can only play tracks, and $id is not one.',
            );
          }

          // A host asking for a video wants the page, not a sound file, and
          // asking YouTube for streams first would be a round trip spent on an
          // answer that is about to be thrown away.
          if (!hints.preferAudioOnly && hints.allowWebEmbed) {
            return _embed(id);
          }

          try {
            return await _stream(id, hints, cancel);
          } on YouTubeStreamException catch (error) {
            return _afterStreamFailure(id, hints, error);
          }
        },
      );

  /// A direct address for [id]'s audio.
  ///
  /// Retried exactly once, and only for a session refusal. YouTube stops
  /// answering a visitor identity it has decided against, and the recovery is
  /// to mint a fresh one — which is a different request rather than the same
  /// one again, so it is worth making. Every other refusal is about the track
  /// or about the approach, and asking twice would only cost time.
  Future<SwayvePlayableSource> _stream(
    SwayveMediaId id,
    SwayvePlaybackHints hints,
    SwayveCancellationToken? cancel,
  ) async {
    try {
      return _sourceFrom(
        parsePlayerResponse(await _client.player(id.value, cancel: cancel)),
        hints,
      );
    } on YouTubeStreamException catch (error) {
      if (error.reason != YouTubeStreamRefusal.sessionRefused) rethrow;
      _client.forgetVisitorData();
      return _sourceFrom(
        parsePlayerResponse(await _client.player(id.value, cancel: cancel)),
        hints,
      );
    }
  }

  /// Turns parsed streams into the source the host plays.
  SwayvePlayableSource _sourceFrom(
    YouTubePlayerStreams streams,
    SwayvePlaybackHints hints,
  ) {
    final YouTubeAudioStream? chosen = streams.preferredAudio(
      // Apple's media stack decodes neither Opus nor WebM, so on those
      // platforms the best rendition YouTube offers is one that would produce
      // silence. Asked as a question about the platform rather than answered
      // as a preference, because that is what it is.
      preferUniversal: _prefersUniversalAudio,
      maxBitrateKbps: hints.maxBitrateKbps,
    );
    if (chosen == null) {
      throw const YouTubeStreamException(
        YouTubeStreamRefusal.extractionClosed,
        'YouTube returned no audio rendition this host could play.',
      );
    }

    return SwayvePlayableSource.directUrl(
      chosen.url,
      // None. The address carries its own signature and is bound to the
      // address it was resolved from; sending a user agent or a referer the
      // service did not ask for is how a signed URL gets refused.
      expiresIn: streams.expiresIn,
      availability: const SwayveAvailability(
        streamable: true,
        // Agreeing with the manifest, which is what the SDK requires of every
        // resolved source. Both were changed together and deliberately — see
        // the class comment.
        downloadable: true,
      ),
      mimeType: chosen.container,
    );
  }

  /// What to do when the streams could not be had.
  ///
  /// The embedded player, wherever the host can render one — a track that can
  /// be watched is better than a track that cannot be played — and the
  /// refusal's own exception otherwise, in the SDK's vocabulary so the host
  /// can tell "this song is gone" from "this source is down".
  SwayvePlayableSource _afterStreamFailure(
    SwayveMediaId id,
    SwayvePlaybackHints hints,
    YouTubeStreamException error,
  ) {
    if (error.reason == YouTubeStreamRefusal.extractionClosed) {
      // Worth a line in the host's log even when the fallback works, because
      // this is the failure nobody would otherwise notice: playback carries on
      // through the embed, downloads quietly stop being possible, and the only
      // evidence is here.
      _log?.warn(error.message);
    }

    if (hints.allowWebEmbed && _embedKind() != null) {
      return _embed(id);
    }

    throw switch (error.reason) {
      YouTubeStreamRefusal.itemUnavailable =>
        SwayvePluginUnsupportedException(error.message),
      YouTubeStreamRefusal.sessionRefused ||
      YouTubeStreamRefusal.extractionClosed =>
        SwayvePluginUnavailableException(error.message),
    };
  }

  /// The embedded player for [id].
  SwayvePlayableSource _embed(SwayveMediaId id) {
    final SwayveWebEmbedKind? kind = _embedKind();
    if (kind == null) {
      throw const SwayvePluginUnsupportedException(
        'YouTube Music plays videos through an embedded player, and this host '
        'renders no web embed.',
      );
    }
    final Uri uri = embedUri(id.value);
    if (!isAllowedHost(uri.host)) {
      // Unreachable with the manifest as written; here so that changing the
      // embed URL without changing the manifest fails loudly rather than
      // quietly handing the host an undeclared destination.
      throw SwayvePluginUnsupportedException(
        'YouTube Music will not hand the host an embed on ${uri.host}: '
        'it is not one of the hosts declared in the plugin manifest.',
      );
    }
    return SwayvePlayableSource.webEmbed(
      SwayveWebEmbed(
        kind: kind,
        uri: uri,
        controls: embedControls,
        // The adapter page, so the host can drive this rather than only look
        // at it. Every YouTube-specific line in the playback path is in
        // `embed_document.dart`; what crosses to the host is the vocabulary in
        // `SwayveEmbedBridge` and nothing else.
        //
        // The origin has to be the address the host loads the page under, and
        // it is: the host is told to use `uri` as the base. YouTube's API
        // refuses a frame whose stated origin disagrees with where it runs.
        document: youTubeEmbedDocument(
          videoId: id.value,
          origin: uri.origin,
        ),
      ),
      // An embed URL does not expire: it is a page, and the player behind it
      // re-resolves its own media. Claiming an expiry would make the host
      // re-resolve for nothing.
      //
      // Streamable and nothing else. A page is not bytes to keep, whatever the
      // manifest allows for the audio path — the SDK reads the source as well
      // as the manifest precisely so the two can differ per resolution.
      availability: SwayveAvailability.streamOnly,
    );
  }

  /// Whether this host needs a rendition every platform can decode.
  bool get _prefersUniversalAudio => switch (_host.platform) {
        SwayvePlatform.ios || SwayvePlatform.macos => true,
        _ => false,
      };

  /// The best embed kind this host can render, or `null` if it renders none.
  SwayveWebEmbedKind? _embedKind() {
    for (final SwayveWebEmbedKind kind in preferredEmbedKinds) {
      if (_host.supportsEmbed(kind)) return kind;
    }
    return null;
  }
}
