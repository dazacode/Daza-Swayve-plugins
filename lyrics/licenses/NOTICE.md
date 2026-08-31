# Third-party notices — Lyrics plugin

## This plugin

Copyright 2026 Swayve. Licensed under the Apache License, Version 2.0. The full
licence text is in `LICENSE` next to this file.

## Bundled third-party code

**None.** This plugin has exactly one dependency, `swayve_plugin_sdk`, which
carries the same Apache-2.0 licence. It bundles no vendored source, no fonts,
and no images other than `assets/icon.svg`, which was drawn for this plugin.

The LRC and TTML parsers in `lib/src/parsing/` are written from scratch rather
than taken from an existing library. That is a licensing convenience and it is
not the reason — see the "Dependencies we deliberately do not have" section of
`youtube_music/README.md`, which this plugin is held to as well: a package that
brings its own HTTP transport cannot be used inside a permission model built on
a host-supplied one.

## The lyrics themselves

This plugin does not hold, ship or redistribute any lyric. It fetches them, on
the device, at the moment a listener asks, from two services:

**LRCLIB** (`lrclib.net`) publishes its corpus under **CC0 1.0**, a public
domain dedication. Nothing is legally required in return. The plugin credits it
anyway, in `SwayveLyrics.source`, because a listener reading a lyric is owed the
name of whoever assembled it — and because a crowd-maintained transcription is a
different kind of claim from a licensed one, which is worth being able to tell.

**BetterLyrics** (`lyrics-api.boidu.dev`) is a free, keyless aggregator. The
documents it returns for anonymous callers come out of its own cache and are
credited to it by name. The plugin ships no API key, requests none, and reads
the service's `401` for an uncached query as "nothing here" rather than as
something to work around.

Neither service is contacted for anything but a lyric lookup, and no request
carries anything about the listener: the query is a title, a credit, an album
and a running time, and nothing else. There is no account, no identifier and no
telemetry.

## The `User-Agent`

Both services are free and neither asks for a key. LRCLIB's documentation asks
instead that a client identify itself and link back to its project, and
`kUserAgent` in `lib/src/config.dart` does exactly that. It is the whole of this
plugin's side of the bargain, and `test/network_allowlist_test.dart` asserts it
is sent on every request.

## Trademarks

"LRCLIB", "BetterLyrics" and "Apple Music" are the marks of their respective
owners. Swayve and this plugin are **not** affiliated with, endorsed by,
sponsored by, or officially connected to any of them.

The names are used **nominatively** — the only accurate way to tell a listener
where a lyric came from is to name the service it came from — and the use is
limited to that:

* `assets/icon.svg` is an original mark drawn for this plugin. It contains no
  logo, wordmark or colour scheme belonging to either service.
* No branding assets from either service are copied, redistributed or
  referenced from this repository.
* The plugin does not present itself as an official product of either service,
  and the host renders it as a third-party plugin named "Lyrics" supplied by
  "Swayve".

The fixtures in `test/fixtures/` are real responses from these services, trimmed
to the first few lines of their lyric. They are committed so the test suite can
run offline and so that a reviewer can see what the parsers are actually written
against; they are not a redistribution of either corpus.
