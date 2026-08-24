import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'innertube_client.dart';
import 'providers/artwork_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/catalog_provider.dart';
import 'providers/library_provider.dart';
import 'providers/metadata_search_provider.dart';
import 'providers/search_provider.dart';
import 'providers/stream_provider.dart';

/// The YouTube Music plugin.
///
/// It declares eight capabilities — `search`, `catalog`, `streaming`,
/// `artwork`, `authentication`, `personal_library`, `session_capture`,
/// `metadata_search` — and registers exactly one provider for each during
/// [initialize] that has one (`webview` and `session_capture` are the two
/// with no provider interface; both are host-driven — see [identity]).
/// It declares three permissions, `network`, `webview` and `external_auth`,
/// and touches exactly the context facilities they guard.
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
  YouTubeMusicAuthProvider? _auth;
  YouTubeMusicLibraryProvider? _library;
  YouTubeMusicMetadataSearchProvider? _metadataSearch;

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

  /// The registered auth provider, or `null` before [initialize].
  YouTubeMusicAuthProvider? get authProvider => _auth;

  /// The registered library provider, or `null` before [initialize].
  YouTubeMusicLibraryProvider? get libraryProvider => _library;

  /// The registered metadata-search provider, or `null` before
  /// [initialize].
  YouTubeMusicMetadataSearchProvider? get metadataSearchProvider =>
      _metadataSearch;

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
          // The two capabilities behind sign-in. `personalLibrary` requires
          // `authentication` be declared too — the validator enforces this —
          // because a signed-in user's own liked songs makes no sense
          // without something that can sign in.
          SwayveCapability.authentication,
          SwayveCapability.personalLibrary,
          // Another capability with no provider interface, same reasoning as
          // `webview` above: the host drives an in-app sign-in itself (via
          // its own `SwayveSessionCaptureController`, triggered from
          // Settings) and writes straight to the credential store keys
          // `authProvider`/`libraryProvider` already read — there is nothing
          // for this plugin to register. Declared so the host knows this
          // plugin supports the flow at all; see `plugin.json`'s
          // `session_capture` block for hosts and capture entries.
          SwayveCapability.sessionCapture,
          // Finds candidates for a track this app has not identified —
          // MusicBrainz's blind spot: extended mixes, bootlegs, unreleased
          // music. See `metadata_search_provider.dart`.
          SwayveCapability.metadataSearch,
        },
        permissions: <SwayvePermission>{
          SwayvePermission.network,
          SwayvePermission.webview,
          // Guards `context.credentials`, which `authProvider` and
          // `libraryProvider` both read the stored `session_cookie` secret
          // through, and is also what makes declaring that `type: "secret"`
          // setting legal in the manifest.
          SwayvePermission.externalAuth,
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
    // Reading `context.credentials` is what asserts the `external_auth`
    // permission, the same way `context.http` above asserted `network`.
    _auth = YouTubeMusicAuthProvider(
      client: client,
      credentials: context.credentials,
      timeouts: timeouts,
    );
    _library = YouTubeMusicLibraryProvider(
      client: client,
      credentials: context.credentials,
      timeouts: timeouts,
    );
    _metadataSearch = YouTubeMusicMetadataSearchProvider(
      client: client,
      timeouts: timeouts,
    );

    context
      ..registerSearchProvider(_search!)
      ..registerCatalogProvider(_catalog!)
      ..registerStreamProvider(_stream!)
      ..registerArtworkProvider(_artwork!)
      ..registerAuthProvider(_auth!)
      ..registerLibraryProvider(_library!)
      ..registerMetadataSearchProvider(_metadataSearch!);

    context.log.info(
      'YouTube Music ready: region ${client.region}, language '
      '${client.language}, embeds ${context.host.supportedEmbeds}.',
    );
  }

  @override
  Future<void> dispose() async {
    // Nothing else to close: the plugin owns no socket, no timer and no
    // isolate. `_auth` is the one exception — it owns a broadcast
    // `StreamController` behind `authStateChanges` — so it is closed
    // explicitly rather than just dropped. `dispose` is safe to call twice
    // or after a failed `initialize`, so closing a controller that may
    // already be null or already closed has to stay harmless too.
    await _auth?.dispose();
    _client = null;
    _search = null;
    _catalog = null;
    _artwork = null;
    _stream = null;
    _auth = null;
    _library = null;
    _metadataSearch = null;
  }
}
