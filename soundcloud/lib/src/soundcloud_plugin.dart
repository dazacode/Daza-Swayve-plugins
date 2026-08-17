import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'config.dart';
import 'providers/artwork_provider.dart';
import 'providers/catalog_provider.dart';
import 'providers/playlist_provider.dart';
import 'providers/search_provider.dart';
import 'providers/stream_provider.dart';
import 'soundcloud_client.dart';

/// The SoundCloud plugin.
///
/// It declares five capabilities — `search`, `catalog`, `streaming`,
/// `artwork`, `playlist_read` — and registers exactly one provider for each
/// during [initialize]. It declares one permission, `network`, and touches
/// exactly the one context facility it guards.
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
        },
        permissions: <SwayvePermission>{
          SwayvePermission.network,
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

    context
      ..registerSearchProvider(_search!)
      ..registerCatalogProvider(_catalog!)
      ..registerStreamProvider(_stream!)
      ..registerArtworkProvider(_artwork!)
      ..registerPlaylistProvider(_playlist!);

    context.log.info('SoundCloud ready.');
  }

  @override
  Future<void> dispose() async {
    // Nothing to close: the plugin owns no socket, no timer, no isolate and
    // no subscription. Dropping the references is the whole of teardown, and
    // it is safe to run twice or after a failed initialize.
    _client = null;
    _search = null;
    _catalog = null;
    _stream = null;
    _artwork = null;
    _playlist = null;
  }
}
