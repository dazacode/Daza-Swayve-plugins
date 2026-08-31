import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'lyrics_client.dart';
import 'providers/lyrics_provider.dart';
import 'sources/betterlyrics_source.dart';
import 'sources/lrclib_source.dart';
import 'sources/lyrics_source.dart';

/// The lyrics plugin.
///
/// One capability, `lyrics`, one permission, `network`, and one provider. That
/// narrowness is the point rather than a limitation: a plugin that declares a
/// single capability is a plugin whose permission screen a person can read in
/// full, and everything it is allowed to do is visible on one line of its
/// manifest.
///
/// It also has no source of its own. It publishes no catalogue, mints no media
/// ids and appears nowhere a listener browses — it exists only to answer a
/// question about somebody else's track, which is why `plugin.json` carries no
/// `source` block while every other plugin in this repository does.
///
/// [initialize] does no network work. The contract gives it eight seconds and
/// says a plugin that blocks past that is degraded; more to the point, a music
/// app that pauses at launch to warm a plugin's cache has made a plugin part of
/// its critical path, which principle 1 forbids. Everything here is
/// construction and registration, and the first request happens when the
/// provider is first called.
final class LyricsPlugin implements SwayvePlugin {
  /// Creates the plugin.
  ///
  /// [timeouts] defaults to the budgets declared in `plugin.json`. Tests pass
  /// millisecond budgets so that proving a deadline fires costs milliseconds.
  LyricsPlugin({this.timeouts = LyricsTimeouts.manifest});

  /// The deadlines the provider works to.
  final LyricsTimeouts timeouts;

  LyricsClient? _client;
  LyricsProvider? _lyrics;

  /// The client both sources share, or `null` before [initialize].
  LyricsClient? get client => _client;

  /// The registered lyrics provider, or `null` before [initialize].
  LyricsProvider? get lyricsProvider => _lyrics;

  @override
  SwayvePluginIdentity get identity => const SwayvePluginIdentity(
        id: kLyricsPluginId,
        name: kLyricsPluginName,
        version: kLyricsPluginVersion,
        swayvePluginApi: kSwayvePluginApiVersion,
        capabilities: <SwayveCapability>{
          // The whole of it. A lyrics provider that also declared `metadata`
          // or `search` would be claiming to be a catalogue, and this plugin
          // has nothing to browse.
          SwayveCapability.lyrics,
        },
        permissions: <SwayvePermission>{
          // The only permission, and the only one there is anything to ask
          // for: no credential store, no web view, no local storage. Both
          // services are keyless, so there is no secret to keep and therefore
          // no `external_auth`.
          SwayvePermission.network,
        },
      );

  @override
  Future<void> initialize(SwayvePluginContext context) async {
    // Reading `context.http` is what asserts the `network` permission: the
    // getter throws SwayvePermissionDeniedException synchronously when the
    // manifest did not declare it, so an over-reach names this line rather than
    // surfacing later as a track that mysteriously has no words.
    final LyricsClient client = LyricsClient(
      http: context.http,
      timeouts: timeouts,
    );
    _client = client;

    _lyrics = LyricsProvider(
      // Best-first, and the order is the ranking: BetterLyrics is the only
      // source with word timing, so it is asked first and a hit there ends the
      // lookup. See `providers/lyrics_provider.dart`.
      sources: <LyricsSource>[
        BetterLyricsSource(client: client),
        LrcLibSource(client: client),
      ],
      timeouts: timeouts,
    );

    context.registerLyricsProvider(_lyrics!);

    context.log.info(
      'Lyrics ready: ${kLyricsAllowedHosts.join(', ')}, no account required.',
    );
  }

  @override
  Future<void> dispose() async {
    // Nothing to close: this plugin owns no socket, no timer, no isolate and no
    // stream controller. `dispose` is safe to call twice and safe to call after
    // a failed `initialize`, which dropping two references trivially is.
    _client = null;
    _lyrics = null;
  }
}
