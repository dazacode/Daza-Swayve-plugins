# SoundCloud — Swayve plugin

Adds SoundCloud search, browsing and playback to Swayve.

| | |
|---|---|
| **Id** | `app.swayve.plugins.soundcloud` |
| **Runtime** | `compiled` — the source lives here and is compiled into a Swayve build |
| **Platforms** | android, ios, windows |
| **Capabilities** | `search`, `catalog`, `streaming`, `artwork`, `playlist_read` |
| **Permissions** | `network` |
| **Network hosts** | `soundcloud.com`, `api-v2.soundcloud.com`, `*.sndcdn.com` |
| **Streamable** | yes |
| **Downloadable** | per track — see [Playback](#playback-progressive-preferred-hls-fallback) |
| **Dependencies** | `swayve_plugin_sdk`. That is the entire list. |

---

## Quick start

```bash
cd plugins/soundcloud
dart pub get
dart analyze     # zero issues
dart test        # offline, deterministic, no network
```

From a host:

```dart
import 'package:soundcloud/soundcloud.dart';

final SwayvePlugin plugin = createSoundCloudPlugin();
await plugin.initialize(context);   // registers five providers, makes zero requests
```

`initialize` does no network work. `SoundCloudClient`'s `client_id` is scraped
lazily on the first request any provider actually makes — a music app that
paused at launch to warm this plugin's credential would have put a plugin on
its critical path, and principle 1 says Swayve works with zero plugins.

---

## Why an unofficial API, not the official one

SoundCloud has an official, OAuth-based API (`client_id` + `client_secret` +
`redirect_uri`, registered per app). It closed new app registrations years
ago, so there is no path for this plugin to obtain its own credentials —
which rules out the "correct" integration outright, not as a preference but
as a fact about what's reachable. The plugin instead does what every other
unofficial SoundCloud client does: scrapes the public `client_id` that
SoundCloud's own web player embeds in its JavaScript bundle, then calls the
public `api-v2.soundcloud.com` JSON API anonymously with it. This is the same
category of move as the YouTube Music reference plugin's InnerTube client —
reverse-engineered, no login required, and built to degrade rather than break
when the upstream service changes its bundle out from under it.

This was researched against two references, neither used as-is:

* `soundcrowd-plugin-soundcloud` (Kotlin, OAuth-based) — its endpoint
  catalogue was a useful map of SoundCloud's API surface, but its transport
  (registered app credentials, HLS-only, `/me/...` endpoints) isn't available
  here.
* `sound-on-fire` (Dart, public `client_id` scrape) — the transport approach
  this plugin follows, but its own implementation only covers search and
  stream resolution with no browsing, pagination, playlists or users; this
  plugin goes considerably further.

---

## Public API

Everything below is exported from `package:soundcloud/soundcloud.dart`.

| Symbol | What it is |
|---|---|
| `createSoundCloudPlugin()` | The `SwayvePluginFactory`. Cheap, synchronous, no side effects. |
| `SoundCloudPlugin` | The `SwayvePlugin`. Holds the five providers; exposes them as nullable getters after `initialize`. |
| `SoundCloudSearchProvider` | `SwayveSearchProvider`. |
| `SoundCloudCatalogProvider` | `SwayveCatalogProvider`. Also `region`, read fresh from settings. |
| `SoundCloudPlaylistProvider` | `SwayvePlaylistProvider` — see [Playlists vs. albums](#playlists-vs-albums). |
| `SoundCloudArtworkProvider` | `SwayveArtworkProvider`. |
| `SoundCloudStreamProvider` | `SwayveStreamProvider`. |
| `SoundCloudClient` | The API client every provider shares. Also `SoundCloudClientIdException`, `SoundCloudPage`. |
| `SoundCloudIds` / `SoundCloudIdKind` | Minting and reading this plugin's provider-native identifiers. |
| `SoundCloudArtwork` | Sizing SoundCloud's image URLs without a request, once the image URL is known. |
| `SoundCloudTimeouts` | The manifest's deadlines, and the seam tests use to shorten them. |
| `kSoundCloudPluginId`, `kSoundCloudPluginName`, `kSoundCloudPluginVersion`, `kSoundCloudAllowedHosts`, `isAllowedHost` | The manifest's facts, restated in code and checked against `plugin.json` by the test suite. |

Nothing in that list requires the host to import it. The host talks to
`SwayveSearchProvider`, `SwayveCatalogProvider`, `SwayveStreamProvider`,
`SwayveArtworkProvider` and `SwayvePlaylistProvider`, and receives
`SwayveTrack`, `SwayveAlbum`, `SwayveArtist`, `SwayvePlaylist`,
`SwayveImageRef` and a generic `SwayvePlayableSource`.

---

## The client, and why it layers over `context.http`

`SoundCloudClient` (`lib/src/soundcloud_client.dart`) owns URL construction,
the `client_id` credential, status interpretation, and JSON decoding. It owns
**no transport** — no socket, no `dart:io`, no `package:http`. Every byte goes
through `SwayvePluginContext.http`, the client the host supplies, for the
same reason the YouTube Music plugin's README gives at length: `SwayveHttpClient`
is *the* place the `network` permission and the manifest's `network.hosts`
allowlist are enforced, and a plugin that opened its own socket would have
escaped that model entirely. Reading `context.http` is also what asserts the
permission — the getter throws `SwayvePermissionDeniedException`
**synchronously**, so an over-reach names the line that did it.

### Dependencies we deliberately do not have

| Package | Why not |
|---|---|
| **Any wrapper around SoundCloud's official SDK** | Requires a registered `client_id`/`client_secret` this plugin cannot obtain — see [above](#why-an-unofficial-api-not-the-official-one). Not a trade-off, a dead end. |
| **Any package bringing its own HTTP stack** (`dio`, `package:http`, etc.) | Every request it made would bypass `context.http` — and therefore the `network` permission and the `network.hosts` allowlist. Same hole the YouTube Music plugin's README describes for `dart_ytmusic_api`. |
| **An HTML parsing package** (`html`, `beautiful_soup_dart`) | The only HTML this plugin ever reads is one page's `<script src="...">` tags, extracted with `RegExp` in `SoundCloudClient._scrapeClientId`. A DOM parser would be real weight for one shallow pattern. |

What replaced them is the client and parsers in `lib/src/`, written against
`context.http`, covered by `dart analyze` and `dart test` with no network
access required for either.

---

## Identifiers

SoundCloud's `track`, `playlist` and `user` ids are all plain integers from a
shared, overlapping numbering space — track `12345` and playlist `12345` are
unrelated. Unlike YouTube Music, where a video id and a browse id are
disjoint shapes a bare value can be classified by, this plugin has to *mint*
a distinguishable id: `SoundCloudIds.mediaId` prefixes the kind (`t12345`,
`p12345`, `u12345`), and `SoundCloudIds.classify`/`kindOf`/`numericValue`
reverse it.

Deliberately **not** encoded in the id: whether a `p`-id currently names a
real album (`is_album: true`) or a plain playlist. That's read fresh from
SoundCloud on every lookup rather than trusted from the prefix, because a
creator can retitle or retype a playlist after this plugin last saw it.
`catalog.album(id)` returns `null` when the freshly-fetched playlist turns
out not to be an album — "wrong kind" reads as "not found," the same
convention YouTube Music's `album`/`artist` lookups already follow.

---

## Playlists vs. albums

The YouTube Music reference plugin folds playlists into its "album" browse
ids, because that's how YouTube Music's own web UI treats them. This plugin
does not mirror that: SoundCloud's data model keeps `is_album` playlists
(real releases) and plain playlists (mixes, "liked tracks"-style sets, DJ
sets) genuinely distinct, and forcing a plain playlist into `SwayveAlbum`
would misrepresent it as a release. The SDK has a capability built for
exactly this case — `playlist_read`, `SwayvePlaylistProvider` — so it's used:
albums surface through `SoundCloudCatalogProvider`, everything else through
`SoundCloudPlaylistProvider`.

Listing results from either carry **no track list**
(`SwayveAlbum.tracks` is always empty from `catalog.albums()`) — per the
SDK's own documented contract for that field: populated by a lookup, not a
listing. Hydrating every cover on a shelf would be one playlist fetch per
tile, bandwidth nobody asked for to draw a grid.

---

## Browse feeds — what backs every listing method, and how sure this is

No listing method here is a stub that always returns empty. Confidence
varies by feed, and that's stated plainly rather than papered over — the same
discipline YouTube Music's README applies to its own browse ids.

| Method | Backed by | Confidence |
|---|---|---|
| `catalog.tracks()` | `/charts` — `recent` → `kind=trending`; everything else → `kind=top`, since `alphabetical` has no chart equivalent and an order with no feed falls back rather than fails. Regioned by the `region` setting. | High — SoundCloud's own web charts page, stable URL shape, used by other unofficial clients. |
| `catalog.artists()` | Derived from the *same* chart response `tracks()` reads: the uploaders of trending/top tracks, deduplicated by user id, no separate request. | The data is real; the framing is honest — this is "uploaders of trending tracks," not a claim that SoundCloud publishes a trending-artists feed of its own (it doesn't, anonymously). |
| `catalog.albums()` | `/playlists/discovery?tag=`, filtered to `is_album: true`. | Medium — plausible and consistent with SoundCloud's own web "Discover" shelves, but this endpoint's exact envelope has not been exercised against live traffic. Both a flat `collection` shape and a `sections[].items`/`.playlists` shelf shape are handled; see `SoundCloudClient.playlistDiscovery`. |
| `SoundCloudPlaylistProvider.playlists()` | Same `/playlists/discovery` call, unfiltered. | Medium, same caveat. |
| `catalog.album(id)` / `catalog.artist(id)` / `playlistTracks(id)` | Direct `/playlists/{id}`, `/users/{id}` lookups. | High — simple id lookups, confirmed by every reference. |

A "Medium" row that guesses wrong about the response shape degrades to fewer
items — it never throws over a shape mismatch, per [Parsing](#parsing--total-never-throws)
below.

---

## Large-playlist hydration

`/playlists/{id}` returns a `tracks` array, but past SoundCloud's own
internal size threshold, entries beyond it arrive as **stubs** —
`{"id": 123, "kind": "track"}` with no title, artist, duration or artwork.
Both references this plugin was researched from implicitly assume this away
— neither handles a playlist long enough to hit it.

`SoundCloudClient.hydratePlaylistTracks` scans for stubs, fetches them via
`tracksByIds` in batches of `kTrackBatchSize` (SoundCloud's own `~50`-id cap
per batch request), and splices the results back into their original
positions so playlist order is preserved — bounded by
`kMaxHydrationBatches` (several hundred tracks; hitting it means something is
wrong, not that somebody owns an unusually long playlist). A batch that fails
to hydrate is skipped: its stubs are simply absent from the result rather
than shown as broken rows, the same "what has been gathered is a truer
answer" reasoning YouTube Music applies to a failed continuation.

SoundCloud's `full` playlist representation returns the whole `tracks` array
in one response rather than paging it with its own `next_href`, so hydration
is the complete answer for one lookup — there's no further playlist-level
cursor to offer beyond it.

---

## Playback: progressive preferred, HLS fallback

A track's `media.transcodings[]` lists every rendition SoundCloud offers.
`SoundCloudStreamProvider` prefers the first `progressive` transcoding — a
single direct media URL the host's own engine plays — and falls back to the
first `hls` transcoding when none is progressive (some Go+-restricted or
HLS-only uploads offer nothing else). Either way the chosen transcoding's own
`url` isn't itself playable: it's resolved once more through
`SoundCloudClient.resolveMediaUrl`, which exchanges it for the final signed
CDN address. No cipher, no signature math to reproduce here — unlike YouTube,
SoundCloud's public API hands back an already-usable URL at that step.

### Downloadable is reported per track

`SwayveAvailability.downloadable` on the resolved source is read straight
from the track's own `downloadable` boolean — never inferred from the fact
that a resolved progressive URL happens to be a fetchable file. Principle 6
(`streamable != downloadable`) exists for exactly this case: SoundCloud
states the permission itself, on a per-track basis, and this plugin repeats
that fact rather than collapsing it into a blanket answer. (Contrast with
YouTube Music, which reports `downloadable: false` for everything — a
different, also-considered policy stance appropriate to a service that states
no such per-item permission.)

`expiresIn` uses a conservative fixed floor (`kStreamLifetime`, minus a
safety margin) rather than a figure the API states — unlike YouTube's player
response, SoundCloud's media-resolution endpoint declares no expiry of its
own in the payload. This is documented as an assumption, not a contract.

A track offering no playable transcoding at all (blocked, region-restricted,
Go+-only with nothing available anonymously) throws
`SwayvePluginUnsupportedException` — "this item cannot be played" — rather
than `Unavailable`, the same distinction YouTube Music draws.

---

## Artwork — costs a request, unlike YouTube Music

`SoundCloudArtwork.resized` rewrites the rendition token on the last path
segment of a `artwork_url`/`avatar_url` (`-large` → `-t200x200`, `-t500x500`,
`-original`, etc.) for free, once the URL is known — the same trick
`YouTubeMusicArtwork.resized` plays on YouTube's thumbnail ladder. But
*getting* that URL is not free here: unlike YouTube, which publishes a
deterministic thumbnail address derivable from a bare video id,
SoundCloud's image URLs exist only on the entity itself, so
`SoundCloudArtworkProvider.artwork(id)` fetches the track/playlist/user
before it can answer at all. This is architecturally different from YouTube
Music's zero-request artwork and is stated as such rather than glossed over.

In practice this path is rarely the hot one: every `SwayveTrack`,
`SwayveAlbum` and `SwayveArtist` this plugin returns from search or catalog
browsing already carries its own artwork inline, sized to
`SwayveArtworkSize.medium`. A host calling this provider directly is asking
for a size it didn't already have cached, or for an id with no inline
artwork.

Images on hosts the manifest doesn't declare are dropped rather than handed
to the host — an image URL on an undeclared host is at best a broken image
and at worst a quiet attempt to widen this plugin's own network reach.

---

## Pagination — the `next_href` cursor

SoundCloud's `next_href` is a **complete URL**, captured with whatever
`client_id` was current when it was minted. The cursor the host holds is that
href, opaque. Following it: parse it, confirm the host is on the allowlist (a
`next_href` pointing elsewhere is a malformed-response condition, not
something to follow blindly), strip and reinject the *current* `client_id`
(it may have rotated since capture), GET it. No manual offset arithmetic
appears in any provider.

**Multi-shelf search** needs up to four continuation tokens in flight at
once — one per requested kind — and the SDK has one cursor slot. All four are
packed into one opaque `sc2|track|album|artist|playlist` string and unpacked
the same way, generalizing `YouTubeMusicSearchProvider`'s two-shelf `_Cursors`
scheme to SoundCloud's four search kinds. A shelf whose cursor came back
`null` is treated as exhausted and not re-queried, so a continuation never
restarts a finished shelf from the top.

---

## Parsing — total, never throws

`lib/src/json_path.dart` provides safe nested access (`dig`, `mapAt`,
`stringAt`, `intAt`, ...) that returns `null` or an empty collection for any
missing key or wrong-shaped value, mirroring YouTube Music's
`json_path.dart`. Every parser in `lib/src/parsing/` is built on it: a single
renamed or absent field degrades one row, never the whole response. Failure
is decided in exactly one place — when the top-level shape isn't the kind of
document the parser asked for at all, which is where
`SwayvePluginMalformedResponseException` is actually warranted.

`SwayveTrackKind` is left at its default (`song`) for every SoundCloud track.
SoundCloud has no equivalent to YouTube Music's two-catalogue (official
releases vs. video uploads) split that `SwayveTrackKind.video` exists to
mark, so introducing a second kind here would claim a distinction the service
doesn't draw — stated explicitly rather than left as an unexplained absence.

---

## Errors, timeouts, cancellation

Every provider method is wrapped in `runGuarded` (`lib/src/errors.dart`):

| What happened | What the host sees |
|---|---|
| HTTP 429 | `SwayvePluginRateLimitedException`, `retryAfter` parsed from the header (delta-seconds or HTTP-date) |
| Any other non-2xx | `SwayvePluginUnavailableException` |
| A `401` that survives one internal `client_id` re-scrape-and-retry | `SwayvePluginUnavailableException` — not auth-required; this plugin declares no `authentication` capability and has no sign-in flow to send anyone through |
| Offline, DNS, TLS, connection reset | `SwayvePluginUnavailableException` (raised by the host's client) |
| Body is not JSON, truncated, or the wrong shape | `SwayvePluginMalformedResponseException` — never a raw `TypeError` |
| The operation outran `timeouts.operationMs` | `SwayvePluginTimeoutException`, carrying the limit |
| The token was cancelled | `SwayvePluginCancelledException` |
| A track offers no playable rendition, or an id is the wrong kind | `SwayvePluginUnsupportedException` |
| Anything unforeseen | `SwayvePluginUnavailableException`, original as `cause` |

Cancellation is checked before any work starts and raced against it
afterwards. Deadlines come from `SoundCloudTimeouts.manifest` and are
injectable, which is how the suite proves a hang is cut off in milliseconds.

---

## Tests

`dart test`. Offline, deterministic, and **no test touches the network** —
every response comes from a committed fixture under `test/fixtures/` through
`FakeSwayveHttpClient`. `test/support.dart`'s `PluginHarness` grants the fake
context exactly the permissions `plugin.json` declares, read from the
manifest at test time.

| File | What it proves |
|---|---|
| `manifest_agreement_test.dart` | Identity/constants/hosts/timeouts/`media` block/the `region` setting all match `plugin.json`; entrypoint matches the directory; exactly the declared capabilities are registered; `initialize` makes no request and fails loudly without `network`; `dispose` is safe twice. |
| `client_id_test.dart` | Both scrape spellings; scripts are tried last-to-first and recover from a decoy trailing script; no match is a clean error, not a crash; a `401` clears the cache, re-scrapes, and retries **exactly once**; a second `401` is reported, not looped; concurrent callers share one in-flight scrape. |
| `search_test.dart` | Normalization, a bad row skipped rather than failing the call, the `is_album` album/playlist split, per-kind endpoint fan-out, the multi-shelf cursor round trip, `limit` on the wire. |
| `catalog_test.dart` | Chart-kind selection per `SwayveSortOrder`, the `region` setting reaching the wire and reacting to a mid-session change, the chart-envelope unwrap, artist deduplication, discovery filtering (both the flat and sectioned shapes), and every lookup's `null`/foreign-id behavior. |
| `playlist_test.dart` | The unfiltered discovery listing, in-order track lookup, stub hydration and splicing, a failed hydration batch degrading gracefully, and foreign/missing-id handling. |
| `stream_test.dart` | Progressive-over-HLS preference and the HLS fallback, per-track `downloadable`, `Unsupported` for an unplayable track or wrong-kind id, `expiresIn`. |
| `artwork_test.dart` | The size-token ladder, the avatar fallback, undeclared-host rejection, and that this path costs a request unlike YouTube Music's. |
| `failure_modes_test.dart` | The full status/timeout/cancellation/malformed-body matrix, on every provider. |
| `network_allowlist_test.dart` | Every outbound request, including the client_id scrape and cursor follow-ups, targets a manifest-declared host; a cursor pointing off-allowlist is rejected rather than followed. |

### Fixture-verified vs. live-validated

**Verified by fixtures:** every parser, every normalization, every
error/timeout/cancellation path, the permission model, and the allowlist
discipline. **Not yet validated against live traffic:** whether the composed
requests are accepted by SoundCloud at all; whether the client_id scrape
still matches the current web bundle; whether `/playlists/discovery`'s shape
— and even its continued existence — matches what's assumed here; every
rate-limit and regional behavior. No request in this repository has ever been
sent to SoundCloud. Treat the parsers as *correct given a payload of the
documented shape*, and the request composition as *plausible but unproven* —
the same honest framing YouTube Music's README applies to its own unverified
browse feeds.

---

## Licence and trademarks

Apache-2.0. See `licenses/LICENSE`.

"SoundCloud" is a trademark of SoundCloud Global Limited & Co. KG. This
plugin is not affiliated with, endorsed by, or connected to SoundCloud. The
name is used nominatively — naming the service is the only accurate way to
say what this plugin talks to — and `assets/icon.svg` is an original mark
drawn for this plugin, deliberately unlike SoundCloud's own logo. The full
position, including on this plugin's use of an unofficial API, is in
`licenses/NOTICE.md`.

Use of the SoundCloud service through this plugin is subject to SoundCloud's
own terms of service.
