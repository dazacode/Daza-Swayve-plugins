# Daza-Swayve-plugins

The plugin catalogue for **Swayve**: first-party plugins today, community
plugins eventually.

**Everything platform-level lives elsewhere, in
[`dazacode/swayve-plugins`](https://github.com/dazacode/swayve-plugins)
(public):** the SDK (`package:swayve_plugin_sdk`), the plugin manifest schema,
the validation/packaging/verification CLI tools, and the specification docs.
This repo depends on that one; it is never the other way around. If you're
looking for how the plugin architecture works, what a manifest is allowed to
say, or how a `.swayveplugin` bundle is built and verified — that's all over
there.

## What's here

| Plugin | What it does |
|---|---|
| [`example`](example/) | The SDK's own reference/teaching plugin — pure Dart, fully offline, small enough to read end to end. Start here if you're writing a new plugin: copy the directory, then work through `swayve-plugins/docs/development.md`. |
| [`youtube_music`](youtube_music/) | YouTube Music search, browsing and playback, via YouTube's unofficial InnerTube API. |
| [`soundcloud`](soundcloud/) | SoundCloud search, browsing and playback, via SoundCloud's public unauthenticated API. |

Each is an independent Dart package — there is no pub workspace here, the
same as `swayve-plugins` itself. `cd` into one and `dart pub get` there.

## Quick start

```bash
cd youtube_music        # or soundcloud, or example
dart pub get
dart analyze             # zero issues
dart test                 # offline, deterministic, no network
```

## The SDK dependency

Every plugin here depends on `swayve_plugin_sdk` as a **pinned git
dependency**, not a path — this repo has no local checkout of
`swayve-plugins` to `path:` against:

```yaml
dependencies:
  swayve_plugin_sdk:
    git:
      url: https://github.com/dazacode/swayve-plugins.git
      path: packages/swayve_plugin_sdk
      ref: <commit sha>
```

Pinned to a commit rather than a floating `main`, for the same reason
`swayve-client` pins its own `swayve-plugins` dependency: a fresh checkout —
CI included — always resolves the exact SDK this plugin was last verified
against, rather than whatever `main` happens to be on the day of the build.
Bumping a plugin to a newer SDK means bumping that one `ref:` line and
re-running its tests.

`analysis_options.yaml` at this repo's root is the shared lint baseline every
plugin here includes (`include: ../analysis_options.yaml`), kept in lockstep
with `swayve-plugins`' own baseline by hand — see the comment at the top of
that file.

## Getting a plugin into a host app

A `runtime: compiled` plugin's Dart code has to be linked into the host
binary at build time. For Swayve itself, that means one more entry in
`swayve-plugins`' `packages/swayve_plugin_registry` — see
[`docs/architecture.md`](https://github.com/dazacode/swayve-plugins/blob/main/docs/architecture.md)
and [`docs/platforms.md`](https://github.com/dazacode/swayve-plugins/blob/main/docs/platforms.md)
there for why. The registry depends on the plugins here the same way they
depend on the SDK: a pinned `git:` dependency, not a path.

## CI

`.github/workflows/validate.yml` and `test.yml` check out this repo
alongside a checkout of `swayve-plugins` (public, no extra credentials
needed) and run that repo's own `tools/validate_plugin.dart` and each
plugin's `dart test` against what's here — so the tooling has exactly one
home and this repo never carries a second copy of it.

Not yet ported here: `swayve-plugins`' tag-triggered `release.yml`, which
packages a single plugin into a `.swayveplugin` bundle and publishes it as a
GitHub Release on push of a `<plugin>-v<semver>` tag. Worth adding if this
repo ever needs to publish bundles on its own rather than through
`swayve-plugins`' tooling run by hand.

## Licence

Each plugin carries its own `licenses/LICENSE` and `licenses/NOTICE.md` —
check the one you're using. Trademark and API-usage notes (which of these
talk to an official API versus an unofficial one, and what that means) are
in each plugin's own `NOTICE.md` and `README.md`.
