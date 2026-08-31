import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'providers/artist_activity_provider.dart';
import 'providers/artwork_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/catalog_provider.dart';
import 'providers/library_provider.dart';
import 'providers/playlist_provider.dart';
import 'providers/radio_provider.dart';
import 'providers/search_provider.dart';
import 'providers/stream_provider.dart';
import 'soundcloud_client.dart';

/// The SoundCloud plugin.
///
/// It declares nine capabilities — `search`, `catalog`, `streaming`,
/// `artwork`, `playlist_read`, `artist_activity`, `authentication`,
/// `personal_library`, `webview` — and registers exactly one provider for
/// each that has one (`webview` has no provider interface of its own — see
/// [identity]). It declares three permissions, `network`, `webview` and
/// `external_auth`, and touches exactly the context facilities they guard.
///
/// [initialize] does no network work of its own. `SoundCloudClient`'s
/// `client_id` is scraped lazily, on the first request any provider actually
/// makes — a music app that paused at launch to warm this plugin's credential
/// would have made a plugin part of its critical path, which principle 1
/// forbids.
final class SoundCloudPlugin implements SwayvePlugin {
  /// Creates the plugin.
  ///
  /// [timeouts] defaults to the budgets declared in `plugin.json`. Tests pass
  /// millisecond budgets so that proving a deadline fires costs milliseconds.
  SoundCloudPlugin({this.timeouts = SoundCloudTimeouts.manifest});

  /// The deadlines every provider works to.
  final SoundCloudTimeouts timeouts;

  SoundCloudClient? _client;
  SoundCloudSearchProvider? _search;
  SoundCloudCatalogProvider? _catalog;
  SoundCloudStreamProvider? _stream;
  SoundCloudArtworkProvider? _artwork;
  SoundCloudPlaylistProvider? _playlist;
  SoundCloudRadioProvider? _radio;
  SoundCloudArtistActivityProvider? _artistActivity;
  SoundCloudAuthProvider? _auth;
  SoundCloudLibraryProvider? _library;

  /// The client every provider shares, or `null` before [initialize].
  SoundCloudClient? get client => _client;

  /// The registered search provider, or `null` before [initialize].
  SoundCloudSearchProvider? get searchProvider => _search;

  /// The registered catalog provider, or `null` before [initialize].
  SoundCloudCatalogProvider? get catalogProvider => _catalog;

  /// The registered stream provider, or `null` before [initialize].
  SoundCloudStreamProvider? get streamProvider => _stream;

  /// The registered artwork provider, or `null` before [initialize].
  SoundCloudArtworkProvider? get artworkProvider => _artwork;

  /// The registered playlist provider, or `null` before [initialize].
  SoundCloudPlaylistProvider? get playlistProvider => _playlist;

  /// The registered radio provider, or `null` before [initialize].
  SoundCloudRadioProvider? get radioProvider => _radio;

  /// The registered artist-activity provider, or `null` before [initialize].
  SoundCloudArtistActivityProvider? get artistActivityProvider =>
      _artistActivity;

  /// The registered auth provider, or `null` before [initialize].
  SoundCloudAuthProvider? get authProvider => _auth;

  /// The registered library provider, or `null` before [initialize].
  SoundCloudLibraryProvider? get libraryProvider => _library;

  @override
  SwayvePluginIdentity get identity => const SwayvePluginIdentity(
        id: kSoundCloudPluginId,
        name: kSoundCloudPluginName,
        version: kSoundCloudPluginVersion,
        swayvePluginApi: kSwayvePluginApiVersion,
        capabilities: <SwayveCapability>{
          SwayveCapability.search,
          SwayveCapability.catalog,
          SwayveCapability.streaming,
          SwayveCapability.artwork,
          SwayveCapability.playlistRead,
          SwayveCapability.radio,
          SwayveCapability.artistActivity,
          // The two capabilities behind sign-in. `personalLibrary` requires
          // `authentication` be declared too — the validator enforces this —
          // because a signed-in user's own liked tracks makes no sense
          // without something that can sign in.
          SwayveCapability.authentication,
          SwayveCapability.personalLibrary,
          // Genuinely used, not merely permission-adjacent: `authProvider`
          // drives `context.webView.presentForResult` directly to run
          // SoundCloud's real OAuth authorization-code flow. See
          // `providers/auth_provider.dart`.
          SwayveCapability.webview,
        },
        permissions: <SwayvePermission>{
          SwayvePermission.network,
          // Guards `context.credentials`, which `authProvider` and
          // `libraryProvider` both read `client_id`/`client_secret`/the
          // OAuth token pair through, and is also what makes declaring
          // those `type: "secret"` settings legal in the manifest.
          SwayvePermission.externalAuth,
          // Guards `context.webView`, which `authProvider` calls directly
          // to present SoundCloud's own sign-in page and capture the OAuth
          // redirect.
          SwayvePermission.webview,
        },
      );

  @override
  Future<void> initialize(SwayvePluginContext context) async {
    // Reading `context.http` is what asserts the `network` permission: the
    // getter throws SwayvePermissionDeniedException synchronously when the
    // manifest did not declare it, so an over-reach names this line rather
    // than surfacing later as a mysterious failed search.
    final SoundCloudClient client = SoundCloudClient(
      http: context.http,
      timeouts: timeouts,
    );
    _client = client;

    _search = SoundCloudSearchProvider(client: client, timeouts: timeouts);
    _catalog = SoundCloudCatalogProvider(
      client: client,
      settings: context.settings,
      timeouts: timeouts,
    );
    _stream = SoundCloudStreamProvider(client: client, timeouts: timeouts);
    _artwork = SoundCloudArtworkProvider(client: client, timeouts: timeouts);
    _playlist = SoundCloudPlaylistProvider(client: client, timeouts: timeouts);
    _radio = SoundCloudRadioProvider(client: client, timeouts: timeouts);
    _artistActivity = SoundCloudArtistActivityProvider(
      client: client,
      timeouts: timeouts,
    );
    // Reading `context.credentials` and `context.webView` is what asserts
    // the `external_auth` and `webview` permissions, the same way
    // `context.http` above asserted `network`.
    _auth = SoundCloudAuthProvider(
      client: client,
      credentials: context.credentials,
      webView: context.webView,
      timeouts: timeouts,
    );
    _library = SoundCloudLibraryProvider(
      client: client,
      credentials: context.credentials,
      timeouts: timeouts,
    );

    context
      ..registerSearchProvider(_search!)
      ..registerCatalogProvider(_catalog!)
      ..registerStreamProvider(_stream!)
      ..registerArtworkProvider(_artwork!)
      ..registerPlaylistProvider(_playlist!)
      ..registerRadioProvider(_radio!)
      ..registerArtistActivityProvider(_artistActivity!)
      ..registerAuthProvider(_auth!)
      ..registerLibraryProvider(_library!);

    context.log.info('SoundCloud ready.');
  }

  @override
  Future<void> dispose() async {
    // `_auth` is the one provider that owns a resource of its own — a
    // broadcast `StreamController` behind `authStateChanges` — so it is
    // closed explicitly rather than just dropped. `dispose` is safe to call
    // twice or after a failed `initialize`, so closing a controller that may
    // already be null or already closed has to stay harmless too.
    await _auth?.dispose();
    _client = null;
    _search = null;
    _catalog = null;
    _stream = null;
    _artwork = null;
    _playlist = null;
    _radio = null;
    _artistActivity = null;
    _auth = null;
    _library = null;
  }
}
