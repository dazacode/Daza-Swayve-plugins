/// The reference Swayve plugin.
///
/// This plugin exists to be read. It does the smallest honest thing a plugin
/// can do — it contributes a handful of tracks, albums and artists to Swayve's
/// search and browsing surfaces — and it does it with no network, no storage,
/// no credentials and no playback. Everything that is left is the shape of a
/// plugin, which is what you are here for.
///
/// ## The five minute version
///
/// A plugin is three things:
///
/// 1. **A manifest** (`plugin.json`) that declares what it can do
///    (`capabilities`) and what it needs to do it (`permissions`). The user
///    approves that at install time and the host enforces it at runtime.
/// 2. **An entry point** — the top-level [example] function below, named after
///    the manifest's `entrypoint`. The host calls it to get an instance.
/// 3. **Providers** — one small interface per capability, registered during
///    [ExamplePlugin.initialize]. Everything the host ever asks this plugin to
///    do, it asks through one of them.
///
/// There is no fourth thing. In particular there is no UI: a plugin returns
/// *data*, and Swayve decides how to draw it. That is not a limitation of the
/// SDK, it is the reason the SDK is pure Dart with no Flutter dependency — a
/// plugin that could inject widgets could break the app's layout, its theme,
/// its accessibility and its frame budget, and "a broken plugin must never
/// break Swayve" is the principle the whole design is bent around.
///
/// ## Where to read next
///
/// * `lib/src/catalogue.dart` — the fixture data, and normalization into SDK
///   models at the plugin's boundary.
/// * `lib/src/providers.dart` — the search and catalog implementations, plus
///   cancellation, deadlines and paging.
/// * `test/` — what all of that is supposed to do, expressed as assertions.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import 'src/catalogue.dart';
import 'src/providers.dart';

export 'src/catalogue.dart' show ExampleCatalogue, examplePluginId;
export 'src/providers.dart' show ExampleCatalogProvider, ExampleSearchProvider;

/// The single symbol this plugin exposes to the host.
///
/// Its name matches `entrypoint` in `plugin.json`, and its type matches
/// `SwayvePluginFactory`. The host resolves the symbol, calls it, and gets a
/// plugin — that is the entire loading protocol for a `compiled` plugin.
///
/// It must stay cheap, synchronous and free of side effects. The host may call
/// it while deciding whether to load the plugin at all, and a factory that
/// opened a connection or read a file would make that decision expensive.
/// All real work belongs in [ExamplePlugin.initialize], which the host calls
/// with a deadline and can abandon.
SwayvePlugin example() => ExamplePlugin();

/// A plugin that contributes a small, fixed catalogue to Swayve.
///
/// ## What its manifest promises, and why the code must agree
///
/// [identity] restates `plugin.json` in Dart. The duplication is deliberate:
/// the manifest is what the *user* approved and what the validator checked,
/// and this is what the *running code* believes. A host is entitled to compare
/// them and refuse to load a plugin whose two answers differ, because a
/// mismatch means the permissions the user granted are not the permissions the
/// code expects. `test/lifecycle_test.dart` asserts the two agree, so a change
/// to one that forgets the other fails here rather than on a device.
final class ExamplePlugin implements SwayvePlugin {
  /// Creates the plugin, optionally over a different [catalogue].
  ///
  /// The seam exists for tests: the shipping plugin always serves
  /// [ExampleCatalogue.fixture], but a test that wants to prove the empty case
  /// behaves sanely can pass [ExampleCatalogue.empty] instead of arranging for
  /// the fixture to be empty. A real plugin's equivalent seam is usually the
  /// service client it talks to.
  ExamplePlugin({ExampleCatalogue? catalogue})
      : _catalogue = catalogue ?? ExampleCatalogue.fixture;

  static const SwayvePluginIdentity _identity = SwayvePluginIdentity(
    id: examplePluginId,
    name: 'Example Plugin',
    version: Version(0, 1, 0),
    swayvePluginApi: kSwayvePluginApiVersion,
    // Two capabilities, so two providers get registered in `initialize` and
    // exactly two. Declaring `streaming` here without registering a
    // `SwayveStreamProvider` would leave the host advertising playback this
    // plugin cannot deliver.
    capabilities: {SwayveCapability.search, SwayveCapability.catalog},
    // Empty, and honestly so. This plugin reads a constant that is compiled
    // into it: no host, no disk, no socket. Asking for `network` "just in
    // case" would cost the user a permission prompt for a facility that is
    // never touched, and over-permissioning is the failure mode the whole
    // permission model exists to make visible.
    permissions: {},
  );

  final ExampleCatalogue _catalogue;

  /// The context the host handed us, or `null` before `initialize` and after
  /// `dispose`.
  ///
  /// Holding it in a nullable field is what makes `dispose` idempotent: the
  /// second call finds `null` and does nothing, instead of using a context the
  /// host has already torn down.
  SwayvePluginContext? _context;

  @override
  SwayvePluginIdentity get identity => _identity;

  @override
  Future<void> initialize(SwayvePluginContext context) async {
    // Registration happens here, and only here. The host builds its routing
    // table from what a plugin registers during initialization — that is how
    // it learns what this plugin can do without knowing what this plugin *is*
    // (there is no `if (plugin.id == 'example')` anywhere in Swayve). A
    // provider registered later may simply be ignored.
    //
    // Note what is *not* happening: no warm-up request, no cache priming, no
    // token refresh. `initialize` runs on the host's startup path under
    // `SwayveTimeouts.initialize`, and a plugin that blocks it is a plugin
    // that makes the app feel slow. Do the minimum, return, and let the first
    // real provider call pay for anything expensive.
    _context = context;
    context.registerSearchProvider(ExampleSearchProvider(_catalogue));
    context.registerCatalogProvider(ExampleCatalogProvider(_catalogue));

    // `log` needs no permission, but it is still the host's channel and not
    // ours: it is attributed to this plugin, and it is read by users filing
    // bug reports. Log facts, never secrets.
    context.log.info(
      'Example plugin ready: ${_catalogue.tracks.length} tracks, '
      '${_catalogue.albums.length} albums, '
      '${_catalogue.artists.length} artists.',
    );
  }

  @override
  Future<void> dispose() async {
    // Everything this plugin holds is immutable and owned by the Dart heap, so
    // there is nothing to close. A plugin with a subscription, a timer or a
    // pending request would cancel it here — teardown runs under
    // `SwayveTimeouts.dispose`, must not depend on the network, and must not
    // throw, including when `initialize` failed halfway through.
    _context?.log.info('Example plugin disposed.');
    _context = null;
  }
}
