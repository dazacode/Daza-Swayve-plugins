import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../config.dart';
import '../errors.dart';
import '../ids.dart';
import '../parsing/item_parser.dart';

/// YouTube Music's answer to `SwayveStreamProvider`. Capability: `streaming`.
///
/// ## What this returns, and what it deliberately does not
///
/// It resolves a track to a `SwayvePlayableSource` of kind `webEmbed` pointing
/// at Google's own embedded player. It does **not** extract a media URL.
///
/// That is a decision, not a limitation. Spec §13 asks that responsibilities
/// be assigned deliberately rather than by reaching for whatever library
/// exists, and stream-URL extraction is the policy-sensitive path it warns
/// about: it works by reproducing the signature logic of a player the service
/// controls, it breaks whenever that player changes, and it takes the plugin
/// somewhere the service has not invited it. The embedded player is the
/// surface Google publishes for exactly this purpose. It also keeps the
/// service's own controls, branding and terms in front of the user at the
/// moment of playback, which is where they belong.
///
/// It follows that this plugin can never offer downloads. §17 is explicit that
/// streamable must not imply downloadable, and here the two are genuinely
/// different: an embed is a page to render, not bytes to keep. The manifest
/// says `media.downloadable: false` and every source returned from here
/// repeats it — the host reads the resolved source, not just the manifest, and
/// the two must agree.
///
/// ## Why it can fail
///
/// `SwayveHostInfo.supportedEmbeds` is checked **first**. A host that renders
/// no web embed cannot play anything this plugin has, and the honest answer is
/// `SwayvePluginUnsupportedException` — the host then drops the track from the
/// queue rather than stalling on it. Degrading silently, by handing back a URL
/// that will fail at playback time, would turn a clear capability mismatch
/// into an unexplained stall.
final class YouTubeMusicStreamProvider implements SwayveStreamProvider {
  /// Creates a provider for [host].
  YouTubeMusicStreamProvider({
    required SwayveHostInfo host,
    this.timeouts = YouTubeMusicTimeouts.manifest,
  }) : _host = host;

  final SwayveHostInfo _host;

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
          if (!hints.allowWebEmbed) {
            throw const SwayvePluginUnsupportedException(
              'YouTube Music plays through an embedded player, and the host '
              'asked for a source that is not a web embed.',
            );
          }
          final SwayveWebEmbedKind? kind = _embedKind();
          if (kind == null) {
            throw const SwayvePluginUnsupportedException(
              'YouTube Music plays through an embedded player, and this host '
              'renders no web embed.',
            );
          }
          final Uri uri = embedUri(id.value);
          if (!isAllowedHost(uri.host)) {
            // Unreachable with the manifest as written; here so that changing
            // the embed URL without changing the manifest fails loudly rather
            // than quietly handing the host an undeclared destination.
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
            ),
            // An embed URL does not expire: it is a page, and the player
            // behind it re-resolves its own media. Claiming an expiry would
            // make the host re-resolve for nothing.
            availability: kYouTubeMusicAvailability,
          );
        },
      );

  /// The best embed kind this host can render, or `null` if it renders none.
  SwayveWebEmbedKind? _embedKind() {
    for (final SwayveWebEmbedKind kind in preferredEmbedKinds) {
      if (_host.supportsEmbed(kind)) return kind;
    }
    return null;
  }
}
