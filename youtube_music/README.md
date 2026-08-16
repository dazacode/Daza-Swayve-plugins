# YouTube Music — Swayve reference plugin

Adds YouTube Music search, browsing and playback to Swayve.

This is the plugin the architecture is proved against. It lives in a separate
repository from the Swayve client, depends on nothing but
`swayve_plugin_sdk`, is **pure Dart with no Flutter dependency**, and requires
the host to know nothing whatsoever about YouTube. If you are writing a plugin,
this is the worked example; if you are implementing the host, this is the thing
that must keep working without a single `if (plugin.id == …)`.

| | |
|---|---|
| **Id** | `app.swayve.plugins.youtube_music` |
| **Runtime** | `compiled` — the source lives here and is compiled into a Swayve build |
| **Platforms** | android, ios, windows |
| **Capabilities** | `search`, `catalog`, `streaming`, `webview`, `artwork` |
| **Permissions** | `network`, `webview` |
| **Network hosts** | `music.youtube.com`, `www.youtube.com`, `i.ytimg.com` |
| **Streamable** | yes |
| **Downloadable** | **no** — deliberately, see below |
| **Dependencies** | `swayve_plugin_sdk`. That is the entire list. |

---

## Quick start

```bash
cd plugins/youtube_music
dart pub get
dart analyze     # zero issues
dart test        # offline, deterministic, no network
```

From a host:

```dart
import 'package:youtube_music/youtube_music.dart';

final SwayvePlugin plugin = createYouTubeMusicPlugin();
await plugin.initialize(context);   // registers four providers, makes zero requests
```

`initialize` does no network work at all. A music app that pauses at launch to
warm a plugin's cache has put a plugin on its critical path, and principle 1
says Swayve works with zero plugins.

> **Note on the SDK dependency.** This plugin's `pubspec.yaml` uses
> `path: ../../packages/swayve_plugin_sdk`. That is a relative path *inside a
> single repository*, which resolves identically on any checkout and on a fresh
> CI runner, so it does not reintroduce the cross-repository coupling that
> [`docs/development.md`](../../docs/development.md) warns about. A plugin
> developed in its **own** repository should use the git dependency described
> there instead.

### The manifest `entrypoint` and the registration symbol

`plugin.json` declares `"entrypoint": "youtube_music"`. That names the
directory (`plugins/youtube_music/`, enforced by the validator) and the library
(`package:youtube_music/youtube_music.dart`). It is **not** the name of the
factory function, because Dart's own lints require lowerCamelCase identifiers
and a `youtube_music()` function would fail this repository's analysis
baseline. The registration symbol is `createYouTubeMusicPlugin`.

---

## Public API

Everything below is exported from `package:youtube_music/youtube_music.dart`.

| Symbol | What it is |
|---|---|
| `createYouTubeMusicPlugin()` | The `SwayvePluginFactory`. Cheap, synchronous, no side effects. |
| `YouTubeMusicPlugin` | The `SwayvePlugin`. Holds the four providers; exposes them as nullable getters after `initialize`. |
| `YouTubeMusicSearchProvider` | `SwayveSearchProvider`. Also `filterFor(SwayveSearchKind)`, the service's own filter token per kind. |
| `YouTubeMusicCatalogProvider` | `SwayveCatalogProvider`, plus `albumTracks(id)` — the SDK has no album-tracks method in v1, but the browse response already carries them. Also `feedFor(SwayveSortOrder?)`. |
| `YouTubeMusicArtworkProvider` | `SwayveArtworkProvider`. |
| `YouTubeMusicStreamProvider` | `SwayveStreamProvider`. Also `embedUri(videoId)`, `embedControls`, `preferredEmbedKinds`. |
| `YouTubeMusicIds` / `YouTubeMusicIdKind` | Reading and minting provider-native ids. |
| `YouTubeMusicArtwork` | Mapping a `SwayveArtworkSize` onto an image, and filtering images to declared hosts. |
| `YouTubeMusicTimeouts` | The manifest's deadlines, and the seam tests use to shorten them. |
| `kYouTubeMusicPluginId`, `kYouTubeMusicPluginName`, `kYouTubeMusicPluginVersion`, `kYouTubeMusicAllowedHosts`, `isAllowedHost` | The manifest's facts, restated in code and checked against `plugin.json` by the test suite. |

Nothing in that list requires the host to import it. The host talks to
`SwayveSearchProvider`, `SwayveCatalogProvider`, `SwayveStreamProvider` and
`SwayveArtworkProvider`, and receives `SwayveTrack`, `SwayveAlbum`,
`SwayveArtist`, `SwayvePlaylist`, `SwayveImageRef` and a generic
`SwayvePlayableSource`. The exported types exist for tests and for anyone
reading the example.

---

## The internal client, and why it layers over `context.http`

`InnerTubeClient` (`lib/src/innertube_client.dart`) is a small, focused client
for YouTube Music's InnerTube API. It owns:

* URL construction for the two endpoints used — `/youtubei/v1/search` and
  `/youtubei/v1/browse`;
* the InnerTube request envelope (`context.client` with `clientName`,
  `clientVersion`, `hl`, `gl`);
* the request headers;
* status-code interpretation;
* JSON decoding and the "is this even the document I asked for" check.

It owns **no transport**. There is no socket, no `dart:io`, no `package:http`,
no connection pool and no cookie jar anywhere in `lib/`. Every byte goes
through `SwayvePluginContext.http`, the client the host supplies:

```dart
InnerTubeClient(
  http: context.http,          // ← the host's client, permission-gated
  settings: context.settings,
  host: context.host,
  timeouts: timeouts,
);
```

That is not a stylistic preference. `SwayveHttpClient` is *the* place the
`network` permission and the manifest's `network.hosts` allowlist are enforced.
A plugin that opened its own socket would still work perfectly, and would have
escaped the permission model entirely — the user would have approved a list of
hostnames that no longer described what the plugin could reach. Reading
`context.http` is also what asserts the permission: the getter throws
`SwayvePermissionDeniedException` **synchronously**, so an over-reach names the
line that did it rather than surfacing later as a mysteriously failing search.

The client goes further than relying on the host: `postJson` refuses to build a
request to a host outside `kYouTubeMusicAllowedHosts` before the host is ever
asked. Belt and braces, and it turns a manifest/code drift into a loud failure
instead of a silent one.

### Reading a setting

The `region` setting is read fresh on every request, in this order: the user's
choice, then `SwayveHostInfo.region`, then the manifest's declared default
(`US`). Caching it at `initialize` would mean a user who changes the setting
keeps getting the old catalogue until they restart the app.

---

## Dependencies we deliberately do not have

This is the section worth reading twice. Spec §13 asks that responsibilities be
assigned deliberately rather than by combining libraries because they exist.
Four obvious candidates were considered and **all four rejected**:

| Package | Why not |
|---|---|
| **`dart_ytmusic_api`** | It brings its own HTTP stack (`dio`). Every request it made would bypass `context.http` — and therefore bypass the `network` permission and the `network.hosts` allowlist. The plugin would be reaching the network through a channel the user never approved and the host cannot see. That is not a trade-off; it is a hole in the security model. |
| **`youtube_explode_dart`** | Same transport problem (`package:http`), plus its purpose is **stream-URL extraction** — the exact policy-sensitive path §13 warns about (see the next section). Depending on it would mean shipping that capability whether or not it was called. |
| **`youtube_player_flutter`** | Drags Flutter into a package that has no UI and needs none. Principle 5 is that plugins supply data and the host renders it, so a plugin has no business owning a player widget. It would also make `dart test` impossible — the suite would need the Flutter test runner for a package with zero widgets. |
| **`flutter_inappwebview`** | Same Flutter problem, and it inverts the architecture: the plugin would be rendering a web view instead of *asking* the host to. `SwayvePlayableSource.webEmbed` exists precisely so the plugin describes an embed and the host decides how to present it. |

What replaced them is roughly 300 lines of client and parser in `lib/src/`,
written against `context.http`. The cost is that this plugin has to understand
InnerTube's response shapes itself. The benefit is that **every capability the
plugin has is one the manifest declares and the host can enforce**, and that
the whole thing is a pure-Dart package a `dart analyze` and a `dart test` can
fully cover.

The general rule this illustrates: a dependency that brings its own transport
cannot be used inside a permission model built on a host-supplied transport.
Check that before you check the API.

---

## Playback: an embedded player, not an extracted stream

`resolvePlayback` returns a `SwayvePlayableSource` of kind `webEmbed` pointing
at Google's own embedded player:

```
https://www.youtube.com/embed/<videoId>?enablejsapi=1&playsinline=1&rel=0
```

It does **not** extract a media URL. That is a decision:

* Extraction works by reproducing the signature logic of a player the service
  controls. It breaks whenever that player changes, which makes a plugin that
  looked healthy yesterday silently useless today.
* It takes the plugin somewhere the service has not invited it. The embedded
  player is the surface Google publishes for exactly this purpose.
* It keeps the service's own controls, branding and terms in front of the user
  at the moment of playback, which is where they belong.

The provider **checks `SwayveHostInfo.supportedEmbeds` first**. A host that
renders no web embed gets `SwayvePluginUnsupportedException` — not a URL that
will fail later. Degrading silently would turn a clear capability mismatch into
an unexplained stall; the host's `_canPlay` path drops an unresolvable track
from the queue, which is the right outcome and only happens if the plugin is
honest. `SwayveWebEmbedKind.inAppWebView` is preferred over `iframe` because it
gives the host a surface it owns; both are supported, and `enablejsapi=1` is
set so the controls the embed advertises (`play`, `pause`, `seek`, `volume`,
`positionUpdates`) are ones the host can actually drive through the player's
own JavaScript API. Advertising a control the host cannot drive would be worse
than advertising none: the SDK says an absent control must be disabled in the
UI, so an over-claim becomes a button that does nothing.

`resolvePlayback` makes **no network request**. It sits on the play path and is
called again whenever a source expires, so it is arithmetic on a video id and
nothing else. `expiresIn` is `null` because an embed URL genuinely does not
expire — the player behind it re-resolves its own media.

### Why `media.downloadable` is `false`

Spec §17: streamable must never imply downloadable. Here the two are genuinely
different facts. An embed is **a page to render, not bytes to keep** — there is
no artefact this plugin could hand the host to store, and no offline right it
holds to grant. So:

* `plugin.json` says `"media": { "streamable": true, "downloadable": false, "offlineCache": false }`;
* every `SwayveTrack` and `SwayveAlbum` reports
  `SwayveAvailability(streamable: true, downloadable: false, onDevice: false)`;
* every `SwayvePlayableSource` repeats it, because the host reads the resolved
  source and not just the manifest, and the two must agree.

There is a test for each of those three. A future contributor who adds stream
extraction would have to change the manifest, the availability constant and the
resolved source together, and would fail the test that compares them.

---

## Artwork the plugin will not show you

`SwayveImageRef` is a location the **host** fetches, through the same
restricted client the plugin would have used. So an image URL on a host the
manifest does not declare is a broken image at best, and at worst a quiet
attempt to widen the plugin's own network reach through the host.

This plugin therefore filters every image reference through the manifest's
allowlist, and the consequences are visible:

* **Track artwork always works.** YouTube publishes a fixed variant ladder
  under `i.ytimg.com/vi/<videoId>/`, so a `SwayveArtworkSize` maps onto a URL
  arithmetically — `default`, `mqdefault`, `hqdefault`, `maxresdefault`. That
  costs **zero requests**, which matters: artwork is asked for once per visible
  row, and a provider that fetched to answer would turn one scroll into fifty
  requests against a rate-limited service.
* **Album and artist artwork works too, as of the cover-art change.** YouTube
  Music serves it from `lh3.googleusercontent.com`, and that host is now
  declared in `network.hosts`.

  It was deliberately left out for a long time, on the reasoning that widening
  the hosts a plugin may reach is a change the user should see and approve
  rather than something a plugin author slips in to make a grid look nicer.
  That reasoning still stands; the difference is that the approval was asked
  for and given. The cost of leaving it out had also become clear: without it
  the only artwork a track could carry was a frame from
  `i.ytimg.com/vi/<videoId>/`, which is 16:9 and letterboxed, so anything
  drawing a record sleeve was stretching a video still into a square.

  Track art now prefers the square cover from the payload and falls back to the
  derived frame only when there is none — a track that is genuinely a video
  rather than a release. Both still cost zero requests.

* **Sizes are asked for, not accepted.** Google's image URLs carry their
  rendition in a suffix on the last path segment (`…/AAxyz=w60-h60-l90-rj`), so
  `YouTubeMusicArtwork.resized` rewrites it to the size the image is actually
  going to be drawn at. A payload offers 60-pixel thumbnails because it was
  describing a list; the same picture at 544 is one string away and costs no
  request. Hosts that do not size their URLs this way are left alone, since
  rewriting one of those turns a working image into a 404.

---

## Where this manifest differs from the contract's canonical example

Two deliberate changes, both called out here because a manifest is a promise:

1. **`network.hosts`** is `["music.youtube.com", "www.youtube.com",
   "i.ytimg.com", "lh3.googleusercontent.com", "*.googlevideo.com"]` rather than
   the example's `["music.youtube.com", "*.googlevideo.com", "i.ytimg.com"]`.
   * `www.youtube.com` was **added**. It is where the official embedded player
     lives, and the plugin hands its URL to the host. It is also where the
     player endpoint answers, the music front end having refused the client
     this plugin has to use.
   * `lh3.googleusercontent.com` was **added**, for the square cover art. See
     the artwork section above for why it was left out for as long as it was.
   * `*.googlevideo.com` is **kept**, and this is the entry worth reading
     twice: it is the media CDN a resolved audio URL points at. The plugin was
     originally written to refuse stream extraction entirely and this host was
     removed to match, on the principle that you do not ask for reach you will
     not use. Extraction was added later, so the reach is used, and the
     declaration is once again the honest one. The wildcard is unavoidable —
     the specific edge host is chosen per request by YouTube.
2. **`webview` is declared as a capability**, not only as a permission. It is
   the one entry in the v1 capability vocabulary with no provider interface
   behind it — the host does the rendering — but the permission has to be
   implied by *some* declared capability or the validator reports the plugin as
   over-permissioned. Declaring it is also simply accurate: this plugin's
   playback is a host-rendered web view.

---

## Errors, deadlines and cancellation

Spec §19: a provider must complete, honour cancellation, or throw a
`SwayvePluginException`. Nothing else may escape. Every provider method here is
wrapped in `runGuarded` (`lib/src/errors.dart`), which is the only place that
decides what a failure was:

| What happened | What the host sees |
|---|---|
| HTTP 429 | `SwayvePluginRateLimitedException`, with `retryAfter` parsed from the header — both delta-seconds and an HTTP-date. An unparseable value is `null`, not a guess. |
| Any other non-2xx | `SwayvePluginUnavailableException` |
| Offline, DNS, TLS, connection reset | `SwayvePluginUnavailableException` (raised by the host's client) |
| Body is not JSON, is truncated, or is JSON of the wrong shape | `SwayvePluginMalformedResponseException` — never a `TypeError` |
| The operation outran `timeouts.operationMs` | `SwayvePluginTimeoutException`, carrying the limit |
| The token was cancelled | `SwayvePluginCancelledException` |
| Host renders no embed / item is not playable | `SwayvePluginUnsupportedException` |
| Anything unforeseen | `SwayvePluginUnavailableException`, with the original as `cause` |

Note what is deliberately absent: **`401`/`403` do not become
`SwayvePluginAuthRequiredException`**. That exception tells the host to send
the user through this plugin's sign-in flow, and this plugin declares no
`authentication` capability and has no such flow. A 403 from the anonymous web
client means a regional or consent block, not a lapsed session, and reporting
auth-required would leave the host offering a button that leads nowhere.

Cancellation is checked before any work starts and raced against the work
afterwards, so a host that has lost interest never waits on an in-flight
request. Deadlines come from the manifest (`YouTubeMusicTimeouts.manifest`) and
are injectable, which is how the suite proves a hanging request is cut off in
milliseconds rather than twenty seconds.

**Parsing degrades, it does not fail.** Navigation through InnerTube's renderer
trees is total — a missing key or a wrong type yields `null`, never an
exception — and failure is a decision made at one place: when the parser has
established the body is not the document it asked for. So a single renamed
field costs the user one row, and the result comes back with
`SwayveSearchResult.partial: true` so the host can say results may be missing.
An unrecognisable body still fails loudly.

---

## Identifiers

`SwayveMediaId.value` holds YouTube Music's **own** id, unwrapped: a video id
like `kJQP7kiw5Fk`, a browse id like `MPREb_9nqEki4ZLqI` or
`UCq3rGZ1Zs9d0dTqRPcJHXyA`. The host never parses it. This plugin does, because
`SwayveCatalogProvider.album` receives nothing but an id and must decide what
to fetch — and it classifies by YouTube's own id shapes rather than by a
private prefix scheme, because those shapes are already disjoint and already
stable. An id whose shape matches nothing is not an error: it is an id this
provider did not mint, and every entry point returns `null` (catalog, artwork)
or `SwayvePluginUnsupportedException` (playback) without making a request.

`extra` carries only things the host must not interpret and that are not
already a field: a track's originating `playlistId`, an artist's
`description` and `subscriberLabel`, a playlist's `VL`-prefixed browse id.

Result classification is also **by endpoint, never by shelf title**. A shelf
headed "Songs" is headed "Canciones" for a Spanish user; keying off it would
make the plugin work in English and quietly return nothing everywhere else.
Every item declares what it is in its navigation endpoint (`watchEndpoint`, or
a `browseEndpoint` with a `pageType` of `MUSIC_PAGE_TYPE_ALBUM` / `_ARTIST` /
`_PLAYLIST`), and those tokens are not localized.

---

## Tests

`dart test`. Offline, deterministic, and **no test touches the network** —
every response comes from a committed fixture under `test/fixtures/` through
`FakeSwayveHttpClient`.

The fake context is granted **exactly the permissions `plugin.json` declares**,
read from the manifest at test time rather than hardcoded. The suite is
therefore also a permission audit: a plugin that reached for a facility it
never asked for fails here rather than on a user's phone.

| File | What it proves |
|---|---|
| `manifest_agreement_test.dart` | Identity, constants, hosts, timeouts and the `media` block all match `plugin.json`; the entrypoint matches the directory; exactly the declared capabilities are registered; `initialize` makes no request and fails loudly without the `network` permission; `dispose` is safe twice. |
| `search_test.dart` | A realistic payload normalizes into `SwayveTrack`/`Album`/`Artist`/`Playlist` with the right ids, artists, album refs, durations and explicit flags; an unreadable row is skipped and reported as `partial`; the continuation token round-trips as a cursor; `kinds` is filtered on the wire *and* in the result; `limit` is a ceiling per kind; the `region` setting reaches the wire and a mid-session change is picked up. |
| `catalog_test.dart` | Feeds partition by kind; `limit` and cursors work; each `SwayveSortOrder` selects a feed and none fails; album and artist lookup read their headers; a foreign or wrong-kind id returns `null` **without a request**; id classification and `SwayveMediaId` round-tripping. |
| `artwork_test.dart` | Each `SwayveArtworkSize` maps onto its own `i.ytimg.com` variant with no request at all; images on undeclared hosts are dropped; images on declared hosts are kept. |
| `stream_test.dart` | `resolvePlayback` returns a `webEmbed` with the expected URL and controls and makes no request; an in-app web view is preferred; an iframe-only host still gets an embed; **an empty `supportedEmbeds` throws `SwayvePluginUnsupportedException`**; so do `allowWebEmbed: false`, a non-track id, and a foreign id; every resolved source reports `downloadable: false` and agrees with the manifest. |
| `failure_modes_test.dart` | 429 → rate-limited with `retryAfter` (seconds, HTTP-date, and unparseable); 5xx and transport failure → unavailable; an exotic error → unavailable with the original as `cause`; 403 → unavailable, *not* auth-required; garbage, truncated and wrong-shaped bodies → malformed, never `TypeError`; a hang → timeout; a cancelled token → cancelled, on every provider. |
| `network_allowlist_test.dart` | **Every outbound request, across every provider, targets a host in `plugin.json`'s `network.hosts`** — checked against the manifest itself, not against the plugin's copy of it. Also: every URL handed onward for the host to fetch (artwork, the embed) is on a declared host, and `isAllowedHost` rejects near-misses such as `music.youtube.com.evil.example.com`. |

### Fixture-verified versus live-validated — read this before trusting it

Be clear about what the green suite does and does not mean.

**Verified by fixtures.** Every parser, every normalization, every error
mapping, every timeout and cancellation path, the permission model, the
allowlist discipline, and the shape of what the host receives. Those are
properties of this code given an input, and the tests pin them exactly.

**Not yet validated against live traffic.** The fixtures' *shapes* are modelled
on InnerTube's real, observed structure — `musicResponsiveListItemRenderer`,
`musicTwoRowItemRenderer`, `musicShelfRenderer`, `musicDetailHeaderRenderer`,
`musicImmersiveHeaderRenderer`, `browseEndpointContextMusicConfig.pageType`,
`continuations[].nextContinuationData.continuation` — but no request in this
repository has ever been sent to YouTube Music. Specifically unverified:

* whether the request as composed here is **accepted** at all: the InnerTube
  client version (`1.20240403.01.00`) ages, and no public API key is sent — if
  live traffic requires one, that is the first thing to discover;
* whether the search **filter tokens** in `YouTubeMusicSearchFilters` still
  scope to the kinds they claim;
* whether the **feed browse ids** (`FEmusic_home`, `FEmusic_new_releases`,
  `FEmusic_charts`) return the shelves assumed here;
* whether **continuation tokens** are accepted in the request body as sent;
* whether the field spellings above are the ones the service currently emits,
  and which of the alternates probed by the parser are actually in use;
* every rate limit, consent wall and regional behaviour, none of which can be
  simulated honestly.

Treat the parsers as *correct given a payload of the documented shape*, and the
request composition as *plausible but unproven*. Validating against live
traffic — and then committing the real payloads as fixtures — is the obvious
next step, and it is the step that would move most of the second list into the
first.

---

## Licence and trademarks

Apache-2.0. See `licenses/LICENSE`.

"YouTube", "YouTube Music" and "Google" are trademarks of Google LLC. This
plugin is not affiliated with, endorsed by, or connected to Google LLC. The
names are used nominatively — naming the service is the only accurate way to
say what this plugin talks to — and `assets/icon.svg` is an original mark
drawn for this plugin, deliberately unlike any Google or YouTube logo. The full
position is in `licenses/NOTICE.md`.

Use of the YouTube Music service through this plugin is subject to Google's own
terms of service.
