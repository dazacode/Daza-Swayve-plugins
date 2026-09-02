# swayve_plugin_registry

The list of first-party compiled Swayve plugins, in one place.

A `runtime: compiled` plugin's Dart code has to be linked into the host app at
build time — that's what makes it safe on iOS, where nothing can download and
execute arbitrary code. A host app that depended on each compiled plugin
directly would need one more `path:`/git dependency and one more import for
every plugin the catalogue ever grows to. This package exists so that never
happens: a host app depends on `swayve_plugin_sdk` and on this package, and
nothing else, no matter how many first-party plugins exist.

```dart
import 'package:swayve_plugin_registry/swayve_plugin_registry.dart';

final factory = firstPartyCompiledPlugins['app.swayve.plugins.youtube_music'];
if (factory != null) {
  final plugin = factory();
  // ...
}
```

## Adding a plugin

1. Add the plugin package as a dependency in this package's `pubspec.yaml`.
2. Add one entry to `firstPartyCompiledPlugins` in `lib/swayve_plugin_registry.dart`.

Nothing in a host app changes.

## What this does not solve

Community plugins. A third-party `compiled` plugin still has to be linked in
by whoever builds that specific binary — there is no way around that on iOS.
This package only removes the *accidental* complexity of the first-party
catalogue growing the host's own dependency list one plugin at a time.
