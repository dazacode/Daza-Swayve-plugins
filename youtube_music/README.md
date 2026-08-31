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
| **Platforms** | android, ios, windows, linux |
| **Capabilities** | `search`, `catalog`, `streaming`, `webview`, `artwork`, `authentication`, `personal_library`, `session_capture` |
| **Permissions** | `network`, `webview`, `external_auth` |
| **Network hosts** | `music.youtube.com`, `www.youtube.com`, `i.ytimg.com`, `lh3.googleusercontent.com`, `yt3.googleusercontent.com`, `yt3.ggpht.com`, `*.googlevideo.com` |
| **Streamable** | yes |
| **Downloadable** | yes — a deliberate reversal of this plugin's earlier embed-only design, see below |
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

## Playback: an extracted stream when it can, an embedded player when it can't

`resolvePlayback` answers one of two ways, chosen by the hints the host sends —
`SwayvePlaybackHints.preferAudioOnly` and `.allowWebEmbed`:

* **Audio** — a direct, already-signed media address for an audio-only
  rendition, extracted from a real player response. The host's own engine
  plays it and can keep it on the device.
* **Video** — the embedded player page, for a host that asked for the video
  rather than the sound file:

  ```
  https://www.youtube.com/embed/<videoId>?enablejsapi=1&playsinline=1&rel=0
  ```

This reverses an earlier decision in this plugin, deliberately — see
`lib/src/providers/stream_provider.dart`'s class comment for the fuller
account. The player endpoint used to be asked as a client (`WEB_REMIX`) that
answers with a signature the plugin would have had to reproduce by executing a
function out of a deliberately obfuscated, multi-megabyte `base.js` — something
no pure-Dart plugin with no JavaScript runtime can do, and something that
breaks the moment that function changes. The player endpoint is now asked as
`VISIONOS` (`lib/src/config.dart`'s `kPlayerClientName`), the one client left
that answers with media addresses **already signed**: no cipher to solve, no
throttling parameter to unscramble, no JavaScript to run. That door is not
guaranteed to stay open forever — `ANDROID`, `IOS` and `ANDROID_VR` all worked
this way once and no longer do — so extraction failing closed
(`YouTubeStreamRefusal.extractionClosed`) falls back to the embedded player
rather than failing outright: the plugin degrades to what it used to be,
instead of breaking.

The embed path still exists for its own reason, independent of extraction: a
host asking for the video wants the picture, not just the sound. The provider
**checks `SwayveHostInfo.supportedEmbeds` first**. A host that renders no web
embed gets `SwayvePluginUnsupportedException` — not a URL that will fail
later. Degrading silently would turn a clear capability mismatch into an
unexplained stall; the host's `_canPlay` path drops an unresolvable track from
the queue, which is the right outcome and only happens if the plugin is
honest. `SwayveWebEmbedKind.inAppWebView` is preferred over `iframe` because it
gives the host a surface it owns; both are supported, and `enablejsapi=1` is
set so the controls the embed advertises (`play`, `pause`, `seek`, `volume`,
`positionUpdates`) are ones the host can actually drive through the player's
own JavaScript API. Advertising a control the host cannot drive would be worse
than advertising none: the SDK says an absent control must be disabled in the
UI, so an over-claim becomes a button that does nothing. `expiresIn` is `null`
for an embed because an embed URL genuinely does not expire — the player
behind it re-resolves its own media — while a resolved audio address carries
the expiry the player response itself stated, less a safety margin.

### Why `media.downloadable` is `true`

Spec §17: streamable must never imply downloadable — the rule matters here
precisely because the answer changed. `media.downloadable` used to be `false`,
back when every resolution was an embed: a page to render, not bytes to keep,
with no artefact this plugin could hand the host to store. That stopped being
the whole story once audio extraction was added — a directly-fetchable media
address genuinely *is* something the host can keep — so `true` is not a default
this plugin fell into but a considered commitment, made deliberately alongside
the extraction change:

* `plugin.json` says `"media": { "streamable": true, "downloadable": true, "offlineCache": false }`;
* every extracted audio `SwayvePlayableSource` reports
  `SwayveAvailability(streamable: true, downloadable: true)`, agreeing with the
  manifest;
* every embedded-player `SwayvePlayableSource`, by contrast, reports
  `SwayveAvailability.streamOnly` — a page is not bytes to keep, whatever the
  manifest allows for the audio path, and the SDK reads the resolved source as
  well as the manifest precisely so the two can differ per resolution.

There is a test for each of those. Fetching media directly still stays
contrary to YouTube's terms — this is a policy commitment, not a technical
one — and downloadable being `true` is a promise the manifest makes about what
the resolved source is capable of, not an endorsement of downloading it.

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
   "i.ytimg.com", "lh3.googleusercontent.com", "yt3.googleusercontent.com",
   "yt3.ggpht.com", "*.googlevideo.com"]` rather than the example's
   `["music.youtube.com", "*.googlevideo.com", "i.ytimg.com"]`.
   * `www.youtube.com` was **added**. It is where the official embedded player
     lives, and the plugin hands its URL to the host. It is also where the
     player endpoint answers, the music front end having refused the client
     this plugin has to use.
   * `lh3.googleusercontent.com` was **added**, for the square cover art. See
     the artwork section above for why it was left out for as long as it was.
   * `yt3.googleusercontent.com` and `yt3.ggpht.com` were **added**, in that
     order and for the same picture: they are two names for one avatar store,
     and which of them an artist's portrait arrives under is decided by
     whatever wrote the payload. The second was held back on the reasoning
     that a portrait is decoration on a search row and that widening granted
     reach to draw a nicer row is not a trade worth asking for. That stopped
     being true when the plugin began answering for a whole artist page, where
     the avatar is the identity of the page rather than trim on somebody
     else's row — see `config.dart`, which keeps both halves of the argument.
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
`SwayvePluginAuthRequiredException`** from `throwForStatus`, even though this
plugin does declare `authentication` now. InnerTube simply does not use those
statuses to say a session has lapsed — a stale or rejected session cookie still
answers `200`, with either the "sign in to see your liked songs" placeholder
(`looksSignedOut`) or, for the player endpoint, a `LOGIN_REQUIRED`
`playabilityStatus`, both handled explicitly where they arise
(`providers/library_provider.dart`, `providers/auth_provider.dart`,
`parsing/stream_parser.dart`). A `401`/`403` reaching `throwForStatus` at all
means something else — a regional or consent block on the anonymous web
client — and reporting auth-required for that would send someone to re-paste a
cookie that was never the problem.

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
already a field: a track's originating `playlistId` and a playlist's
`VL`-prefixed browse id. An artist's description and subscriber count used to
live here too, and moved onto `SwayveArtist`'s own fields once the SDK grew
them — `extra` is where a fact goes when the contract has nowhere for it, not a
second home for facts the contract now names.

Result classification is also **by endpoint, never by shelf title**. A shelf
headed "Songs" is headed "Canciones" for a Spanish user; keying off it would
make the plugin work in English and quietly return nothing everywhere else.
Every item declares what it is in its navigation endpoint (`watchEndpoint`, or
a `browseEndpoint` with a `pageType` of `MUSIC_PAGE_TYPE_ALBUM` / `_ARTIST` /
`_PLAYLIST`), and those tokens are not localized.

The artist page's **shelves** are classified the same way, one level up: a
shelf takes its kind from what its first item turned out to be, not from the
heading above it. The two shelves that need a second question after that are
albums against singles — told apart by whether the tile's subtitle is
`Album • 2023` or a bare year, a *shape* rather than a word — and songs against
videos, which each row's own `musicVideoType` has already answered.

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
| `catalog_test.dart` | Feeds partition by kind; `limit` and cursors work; each `SwayveSortOrder` selects a feed and none fails; album lookup reads its header and its listing; a foreign or wrong-kind id returns `null` **without a request**; id classification and `SwayveMediaId` round-tripping. Artist lookup gets its own group: the header's subscriber, monthly-listener, description, avatar, banner, play and radio fields; all six shelves parsed in payload order and classified by their contents rather than their (English) titles; albums told from singles by subtitle shape; songs told from videos by `musicVideoType`; a page with only songs, and one whose header is `musicVisualHeaderRenderer`. |
| `artwork_test.dart` | Each `SwayveArtworkSize` maps onto its own `i.ytimg.com` variant with no request at all; images on undeclared hosts are dropped; images on declared hosts are kept. |
| `stream_test.dart` | Audio resolution: a preferred rendition is chosen by codec support and bitrate ceiling, the visitor identity is minted once and reused (and re-minted on a refused session), duration and expiry are read honestly, and the resolved source's `downloadable: true` agrees with the manifest. Video/embed resolution: `resolvePlayback` returns a `webEmbed` with the expected URL and controls and makes no request; an in-app web view is preferred; an iframe-only host still gets an embed; **an empty `supportedEmbeds` throws `SwayvePluginUnsupportedException`**; an embed's `SwayveAvailability` is stream-only, never claiming a download right. Degradation: extraction closing falls back to the embed and logs a warning; a host with no embed gets unavailable instead; a non-track id and a foreign id are refused without a request. |
| `failure_modes_test.dart` | 429 → rate-limited with `retryAfter` (seconds, HTTP-date, and unparseable); 5xx and transport failure → unavailable; an exotic error → unavailable with the original as `cause`; 403 → unavailable, *not* auth-required, on the anonymous surface these tests exercise; garbage, truncated and wrong-shaped bodies → malformed, never `TypeError`; a hang → timeout; a cancelled token → cancelled, on every provider. |
| `network_allowlist_test.dart` | **Every outbound request, across every provider, targets a host in `plugin.json`'s `network.hosts`** — checked against the manifest itself, not against the plugin's copy of it. Also: every URL handed onward for the host to fetch (artwork, the embed) is on a declared host, and `isAllowedHost` rejects near-misses such as `music.youtube.com.evil.example.com`. |
| `sapisid_hash_test.dart` | `sha1Bytes` against the standard NIST test vectors (empty string, `"abc"`, the pangram, a multi-block message); `sapisidHashAuthorization` reads `__Secure-3PAPISID` ahead of plain `SAPISID`, falls back correctly, handles a cookie value containing `=`, and is `null` when neither cookie is present. |
| `auth_provider_test.dart` | `authState` never touches the network and answers from whether a cookie is stored; `authenticate` fails without a request when nothing is stored, becomes signed in for a cookie InnerTube answers for, and becomes a failed (never thrown) state for a rejected or malformed response; a validated cookie is reused by a later `authState` call; `signOut` deletes the stored secret and never throws; `authStateChanges` sends a new listener the current state immediately, is a broadcast stream, and publishes every later change. |
| `library_provider_test.dart` | A signed-out call throws auth-required rather than returning an empty page; a signed-in call parses liked tracks through the shared feed parser, hands back an empty (not error) page for nothing liked yet, and round-trips the cursor; the browse carries the stored cookie, a computed `authorization` header, and the stored `page_id` as `x-goog-pageid` when one is configured; the browse id is the liked-songs playlist; an empty stored cookie is treated as signed out; cancellation is honoured. |

### Fixture-verified versus live-validated — read this before trusting it

Be clear about what the green suite does and does not mean.

**Verified by fixtures.** Every parser, every normalization, every error
mapping, every timeout and cancellation path, the permission model, the
allowlist discipline, and the shape of what the host receives. Those are
properties of this code given an input, and the tests pin them exactly.

**Confirmed live, against real accounts.** Since this section was first
written, the signed-in path has actually been exercised against
`music.youtube.com` — not just modelled on its observed shapes:

* the `session_cookie` → `SAPISIDHASH` `Authorization` header this plugin
  computes (`lib/src/auth/sapisid_hash.dart`) is accepted by InnerTube for a
  real signed-in session;
* browsing the Liked Music playlist (`VLLM`) for that session, including
  paging past the first response — InnerTube answers a continuation's second
  page in a flatter shape than the first (`onResponseReceivedActions[]
  .appendContinuationItemsAction.continuationItems` rather than
  `continuationContents`), which only surfaced by trying it live;
* the signed-out placeholder (`looksSignedOut`) and its distinction from a
  genuinely empty Liked Music playlist;
* `x-goog-pageid` selecting the right channel on a real multi-channel
  account — confirmed empirically, not merely inferred from other clients:
  without it, a channel's own Liked Music answered as a normal, parseable,
  entirely *empty* page, with it, the real count.

See `providers/library_provider.dart`, `providers/auth_provider.dart`,
`parsing/feed_parser.dart` and `auth/sapisid_hash.dart` for exactly what each
of those doc comments claims and where.

**Not yet validated against live traffic.** Everything else — the fixtures'
*shapes* are modelled on InnerTube's real, observed structure —
`musicResponsiveListItemRenderer`, `musicTwoRowItemRenderer`,
`musicShelfRenderer`, `musicDetailHeaderRenderer`,
`musicImmersiveHeaderRenderer`, `browseEndpointContextMusicConfig.pageType`,
`continuations[].nextContinuationData.continuation` — but the anonymous
search/browse/streaming surface has not itself been exercised against live
traffic as part of this repository's own testing. Specifically unverified:

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
anonymous-surface request composition as *plausible but unproven* — the
signed-in path above is the one part of this list that has moved from
"plausible" to "confirmed." Validating the rest against live traffic — and
then committing the real payloads as fixtures — is the obvious next step.

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
