# Third-party notices — SoundCloud plugin

## This plugin

Copyright 2026 Swayve. Licensed under the Apache License, Version 2.0. The full
licence text is in `LICENSE` next to this file.

## Bundled third-party code

**None.** This plugin has exactly one dependency, `swayve_plugin_sdk`, which is
part of this repository and carries the same Apache-2.0 licence. It bundles no
vendored source, no fonts, and no images other than `assets/icon.svg`, which was
drawn for this plugin.

See the "Dependencies we deliberately do not have" section of `README.md` for
why the official SoundCloud SDK and every HTTP-carrying pub package were
considered and rejected.

## Trademarks

"SoundCloud" is a trademark of SoundCloud Global Limited & Co. KG. Swayve and
this plugin are **not** affiliated with, endorsed by, sponsored by, or in any
way officially connected to SoundCloud or any of its subsidiaries.

The name is used here **nominatively** — the only accurate way to tell a user
which service this plugin talks to is to name it. Nominative use is limited to
that, and this plugin observes the limits:

* `assets/icon.svg` is an original mark drawn for this plugin. It contains no
  SoundCloud logo, wordmark, waveform mark, colour scheme, or shape derived
  from either.
* No SoundCloud branding assets are copied, redistributed, or referenced from
  this repository.
* The plugin does not present itself as an official SoundCloud product, and
  the host renders it as a third-party plugin named "SoundCloud" supplied by
  "Swayve".

## On the API this plugin uses

This plugin talks to SoundCloud's public `api-v2.soundcloud.com` JSON API
anonymously, authenticating requests with a `client_id` scraped from
SoundCloud's own public web client rather than one issued through SoundCloud's
official app-registration process — see `README.md` for why (SoundCloud closed
new API app registrations years ago, so no registered `client_id` is obtainable
for a plugin like this one). This is the same approach taken by the numerous
other unofficial SoundCloud clients that exist for the same reason, and it is
**not sanctioned by SoundCloud**. Use of the SoundCloud service through this
plugin is subject to SoundCloud's own terms of service, and this plugin's
continued function depends entirely on SoundCloud's public API and web bundle
staying stable in ways SoundCloud has made no commitment to.
