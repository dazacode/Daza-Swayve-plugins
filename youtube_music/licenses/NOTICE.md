# Third-party notices — YouTube Music plugin

## This plugin

Copyright 2026 Swayve. Licensed under the Apache License, Version 2.0. The full
licence text is in `LICENSE` next to this file.

## Bundled third-party code

**None.** This plugin has exactly one dependency, `swayve_plugin_sdk`, which is
part of this repository and carries the same Apache-2.0 licence. It bundles no
vendored source, no fonts, and no images other than `assets/icon.svg`, which was
drawn for this plugin.

See the "Dependencies we deliberately do not have" section of `README.md` for why
the obvious YouTube client libraries are absent.

## Trademarks

"YouTube", "YouTube Music" and "Google" are trademarks of Google LLC. Swayve and
this plugin are **not** affiliated with, endorsed by, sponsored by, or in any way
officially connected to Google LLC or any of its subsidiaries.

The names are used here **nominatively** — the only accurate way to tell a user
which service this plugin talks to is to name it. Nominative use is limited to
that, and this plugin observes the limits:

* `assets/icon.svg` is an original mark drawn for this plugin. It contains no
  Google or YouTube logo, wordmark, colour scheme, or shape derived from either.
  It is deliberately unlike the YouTube play-button mark.
* No Google or YouTube branding assets are copied, redistributed, or referenced
  from this repository.
* The plugin does not present itself as an official YouTube or Google product,
  and the host renders it as a third-party plugin named "YouTube Music" supplied
  by "Swayve".

Playback is handed to Google's own embedded player (see `README.md`), so the
service's own branding, controls and policies are what the user actually sees at
playback time. That is intentional: it is the arrangement that keeps the
trademark position, the licensing position and the technical position aligned
rather than in tension.

Use of the YouTube Music service through this plugin is subject to Google's own
terms of service. Nothing in this repository grants any right to that service.
