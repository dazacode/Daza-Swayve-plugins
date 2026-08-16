import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'innertube_client.dart';
import 'providers/artwork_provider.dart';
import 'providers/catalog_provider.dart';
import 'providers/search_provider.dart';
import 'providers/stream_provider.dart';

/// The YouTube Music plugin.
///
/// It declares four capabilities — `search`, `catalog`, `streaming`,
/// `artwork` — and registers exactly one provider for each during
/// [initialize]. It declares two permissions, `network` and `webview`, and
/// touches exactly the two context facilities they guard.
///
/// [initialize] does no network work. The contract gives it eight seconds and
/// says a plugin that blocks past that is degraded; more to the point, a music
/// app that pauses at launch to warm a plugin's cache has made a plugin part
/// of its critical path, which principle 1 forbids. Everything here is
/// construction and registration, and the first request happens when a
/// provider is first called.
final class YouTubeMusicPlugin implements SwayvePlugin {
  /// Creates the plugin.
  ///
  /// [timeouts] defaults to the budgets declared in `plugin.json`. Tests pass
  /// millisecond budgets so that proving a deadline fires costs milliseconds.
  YouTubeMusicPlugin({this.timeouts = YouTubeMusicTimeouts.manifest});

  /// The deadlines every provider works to.
  final YouTubeMusicTimeouts timeouts;

  InnerTubeClient? _client;
  YouTubeMusicSearchProvider? _search;
  YouTubeMusicCatalogProvider? _catalog;
  YouTubeMusicArtworkProvider? _artwork;
  YouTubeMusicStreamProvider? _stream;

  /// The client every provider shares, or `null` before [initialize].
  InnerTubeClient? get client => _client;

  /// The registered search provider, or `null` before [initialize].
  YouTubeMusicSearchProvider? get searchProvider => _search;

  /// The registered catalog provider, or `null` before [initialize].
  YouTubeMusicCatalogProvider? get catalogProvider => _catalog;

  /// The registered artwork provider, or `null` before [initialize].
  YouTubeMusicArtworkProvider? get artworkProvider => _artwork;

  /// The registered stream provider, or `null` before [initialize].
  YouTubeMusicStreamProvider? get streamProvider => _stream;

  @override
  SwayvePluginIdentity get identity => const SwayvePluginIdentity(
        id: kYouTubeMusicPluginId,
        name: kYouTubeMusicPluginName,
        version: kYouTubeMusicPluginVersion,
        swayvePluginApi: kSwayvePluginApiVersion,
        capabilities: <SwayveCapability>{
          SwayveCapability.search,
          SwayveCapability.catalog,
          SwayveCapability.streaming,
          // `webview` is the one capability with no provider interface: the
          // host does the rendering. It is declared because playback resolves
          // to a web embed, which is a request for a host-rendered web view —
          // and because declaring the `webview` permission without it would
          // leave the plugin over-permissioned by the validator's own rule.
          SwayveCapability.webview,
          SwayveCapability.artwork,
        },
        permissions: <SwayvePermission>{
          SwayvePermission.network,
          SwayvePermission.webview,
        },
      );

  @override
  Future<void> initialize(SwayvePluginContext context) async {
    // Reading `context.http` is what asserts the `network` permission: the
    // getter throws SwayvePermissionDeniedException synchronously when the
    // manifest did not declare it, so an over-reach names this line rather
    // than surfacing later as a mysterious failed search.
    final InnerTubeClient client = InnerTubeClient(
      http: context.http,
      settings: context.settings,
      host: context.host,
      timeouts: timeouts,
    );
    _client = client;

    _search = YouTubeMusicSearchProvider(
      client: client,
      settings: context.settings,
      timeouts: timeouts,
    );
    _catalog = YouTubeMusicCatalogProvider(client: client, timeouts: timeouts);
    _artwork = YouTubeMusicArtworkProvider(client: client, timeouts: timeouts);
    _stream = YouTubeMusicStreamProvider(
      host: context.host,
      client: client,
      log: context.log,
      timeouts: timeouts,
    );

    context
      ..registerSearchProvider(_search!)
      ..registerCatalogProvider(_catalog!)
      ..registerStreamProvider(_stream!)
      ..registerArtworkProvider(_artwork!);

    context.log.info(
      'YouTube Music ready: region ${client.region}, language '
      '${client.language}, embeds ${context.host.supportedEmbeds}.',
    );
  }

  @override
  Future<void> dispose() async {
    // Nothing to close: the plugin owns no socket, no timer, no isolate and
    // no subscription. Dropping the references is the whole of teardown, and
    // it is safe to run twice or after a failed initialize.
    _client = null;
    _search = null;
    _catalog = null;
    _artwork = null;
    _stream = null;
  }
}
