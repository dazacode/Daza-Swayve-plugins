# Lyrics — a source-agnostic lyrics plugin

Finds the words to whatever is playing, wherever it came from.

This is the first plugin in this repository with **no catalogue of its own**. It
publishes no tracks, mints no media ids and appears nowhere a listener browses.
It exists to answer one question — *what are the words to this recording* — about
tracks that some **other** plugin published: a song from YouTube Music, a set
from SoundCloud, a file out of a listener's own iBroadcast library. All three
arrive as a `SwayveTrack` and all three are looked up the same way.

| | |
|---|---|
| **Id** | `app.swayve.plugins.lyrics` |
| **Runtime** | `compiled` — the source lives here and is compiled into a Swayve build |
| **Platforms** | android, ios, windows, linux, macos |
| **Capabilities** | `lyrics`. That is the whole list. |
| **Permissions** | `network`. That is the whole list. |
| **Network hosts** | `lrclib.net`, `lyrics-api.boidu.dev` |
| **Accounts / API keys** | none, and none requested |
| **Dependencies** | `swayve_plugin_sdk`. That is the entire list. |

---

## Quick start

```bash
cd lyrics
dart pub get
dart analyze --fatal-infos .   # zero issues
dart test                      # offline, deterministic, no network
dart format --output=none --set-exit-if-changed .
```

From a host:

```dart
import 'package:lyrics/lyrics.dart';

final SwayvePlugin plugin = createLyricsPlugin();
await plugin.initialize(context);   // registers one provider, makes zero requests

final SwayveLyrics? words = await provider.lyrics(nowPlaying);
```

`initialize` does no network work at all. A music app that pauses at launch to
warm a plugin's cache has put a plugin on its critical path, and principle 1 says
Swayve works with zero plugins.

---

## Why a whole track and not a media id

The SDK widened `SwayveLyricsProvider.lyrics` to take a `SwayveTrack` rather than
a `SwayveMediaId`, and that widening is this plugin's entire reason to exist.

A media id is opaque by design. An id minted by the YouTube Music plugin means
nothing to anybody else, and a second plugin picking it apart would be exactly
the provider-specific knowledge the SDK keeps out of everything. A whole track is
different: it carries the title, the credit, the release and the running time.
That is enough to find a recording in somebody else's catalogue — and, just as
importantly, **enough to decide the match is not good enough**.

So there is no `if (plugin.id == …)` in this plugin and no id parsing anywhere in
it. `test/lyrics_provider_test.dart` proves it: the same track published under
two different plugins' ids produces the same request and the same answer.

---

## The two sources, and what they really are

The specification this plugin was written to was wrong about one of them in three
separate ways. Everything below is what the live services returned in August 2026.

### LRCLIB — primary for synced lyrics

Free, keyless, CC0, and the best answer available to "what are the words to this
recording, timed to it".

* `GET /api/get?track_name=&artist_name=&album_name=&duration=` returns one
  record or `404`.
* `GET /api/search?track_name=&artist_name=` returns up to twenty candidates and
  adjudicates nothing.

Two things measured against the live endpoint that shape the code:

**`/api/get` answering `200` does not mean it found *your* recording.** Asking for
a 260-second "Blinding Lights" answers with a **261-second** record, and asking
with no `duration` at all still answers `200` with a record of the service's own
choosing. So every record is checked against the track before it is believed,
using the four fields the record itself carries.

**A record now also carries `lyricsfile`**, a YAML rendering of the same lyric
that the brief did not mention. It is ignored: it says nothing `syncedLyrics` does
not, and parsing a second serialization of the same data would be a second thing
to keep working.

`instrumental: true` arrives with both lyric fields `null`. That is the service
saying the recording has no words, and it comes back as "none found".

### BetterLyrics — the only source of word-level timing

Free, keyless, and **not** what the brief described. Three findings:

**The answer is TTML, not a JSON word array.** `GET /getLyrics` returns
`{"ttml": "<tt …>"}` — one string field holding an Apple Music word-timed TTML
document, with `<p>` for a line and `<span begin end>` for a word. The sibling
route `/ttml/getLyrics` returns the same document under the key `lyrics`, so both
keys are read. `lib/src/parsing/ttml_parser.dart` is written to what actually
comes back.

**The parameters are `s` and `a`.** Published at the service's own root document:
`s`/`song`/`songName` and `a`/`artist`/`artistName` required, `al`/`album`/
`albumName` and `d`/`duration` optional. The short forms are sent, and all four
whenever the track carries them.

**Anonymous callers get the cache and only the cache.** A query the service has
not answered recently comes back `401`:

```json
{"error":"API key required","message":"Uncached queries require a valid API key via X-API-Key header"}
```

A cached one comes back `200` with `x-auth-mode: cache` and `x-cache-status: HIT`.
This plugin holds no key and asks for none — a first-party plugin shipping a
credential would be shipping a shared secret to every device — so `401` is read as
"this service has nothing for you", which is precisely what it means for a caller
in this position. It is emphatically **not** reported as an authentication
problem: there is no sign-in that would fix it, and reporting one would send a
listener looking for a setting that does not exist.

The practical consequence is a clean division of labour. BetterLyrics answers for
popular recordings and declines for everything else; LRCLIB carries the rest of
the library.

---

## Ranking, and the order the sources are asked in

Word-level beats synced beats plain. So:

1. **BetterLyrics** is asked first, because it is the only source with word
   timing. A word-timed answer ends the lookup — one request.
2. **LRCLIB** is asked when it declines, and its answer is kept.

At most two requests, usually two. Every alternative ordering costs the same two
in the common case and loses the chance of stopping after one.

Whatever comes back carries all three forms it can: a document with word timing
also publishes synced lines and plain text, because the SDK asks a provider
holding one form to fill in the others and a host with no karaoke view must not
come away empty because the timing was too good.

---

## Saying no is the normal answer

Most recordings in a real library have never been transcribed by anybody. `null`
is what this plugin returns for them, it is not an error, and a host must be able
to ask about a hundred tracks and be told no a hundred times without anything
being reported as degraded.

That creates a problem worth being explicit about: **a service that is down also
produces no lyrics.** If the two looked the same from inside the plugin, a total
outage would be indistinguishable from a quiet afternoon and nobody would ever
notice.

So a source answers with a `SourceAttempt` — *found*, *none*, or *failed* — and
the provider applies the rule that follows:

* any source found something → return the best of them;
* nothing found, but at least one source got as far as an honest "not here" →
  `null`;
* **every** source failed → rethrow, because that is the only case in which
  nothing was learned.

One service being down while the other answers is not reported at all. The
listener got their lyric; there is nothing for them to do about it.

---

## The matching guard

`lib/src/matching.dart` is the file to distrust, and it has its own test file for
that reason. Everything else here is a parser or a request, and a parser that is
wrong produces something visibly broken. This produces something that looks
completely fine and is the words to a different song.

**A wrong match is worse than no match.** Where there is a choice, it refuses.

Titles and credits are normalized before comparing — case-folded, diacritic-folded,
bracketed clauses dropped, `- Topic` and `VEVO` taken off a credit, punctuation
removed, whitespace collapsed — and then they must **agree**, not merely be
similar. Edit distance was considered and rejected: the distance between `Heroes`
and `Heroine` is exactly the distance between two spellings of one title, and a
threshold that admits the second admits the first.

Then the running time decides, within **two seconds** — LRCLIB's own tolerance:

| | |
|---|---|
| title and credit disagree | **rejected** |
| both durations known and within 2s | **timed** — everything usable |
| both known, further apart | **rejected** |
| either duration unknown | **plainOnly** — the words, and no timings |

That last row is the interesting one. Title and credit together do not identify a
recording: a single, its album cut, its radio edit, a remaster and a live take
share both. The words are overwhelmingly the same across all of them; the
*timings* are not. So without a duration to tell them apart, the plain lyric is
published and the synced one is dropped. A plain lyric from the wrong cut is
right. A synced one drifts further out of time with every chorus, which reads as
a broken player rather than as a near miss.

The numbers behind that are real. One observed LRCLIB search page for a single
recording returned five results under the same title and credit, running 202, 202,
202, 248 and 263 seconds — three of them the recording being played and two of
them compilation edits. Nothing but the duration separates them, and the search
fixture committed in `test/fixtures/lrclib_search.json` is that page.

---

## What this plugin deliberately does not do

**Romanize.** A Japanese lyric comes back in Japanese. Romanization needs a real
dictionary; the packages that hold one bring `package:http` with them; and a
dependency that brings its own transport cannot be used inside a permission model
built on a host-supplied transport. It is host-side work, and the SDK's
`SwayveAlternateNames` is where a romanization belongs when the host produces one.

**Bring an XML or HTML parser.** Same rule, and it is the reason there are two
hand-written parsers in `lib/src/parsing/`. They were cheaper to write than the
hole would have been to close. See the "Dependencies we deliberately do not have"
section of `youtube_music/README.md`, which this plugin is held to as well.

**Scrape.** Both hosts on the allowlist are APIs that were offered as APIs.
Reading a page that was never offered as one is a different thing, and it is not
what this plugin does.

**Cache.** A lookup is one GET and the answer is the host's to remember. A plugin
keeping its own cache would be keeping it in memory the host cannot see or
reclaim.

**Ask for anything it does not need.** One capability, one permission, no
settings, no account, no credential store, no web view, no local storage. The
permission screen for this plugin is one line long, and that is the point.

---

## Layout

```
lyrics/
├── plugin.json                        the manifest; the code agrees with it by test
├── lib/
│   ├── lyrics.dart                    the entrypoint library and createLyricsPlugin()
│   └── src/
│       ├── config.dart                every constant with a counterpart in plugin.json
│       ├── errors.dart                the one place a failure becomes an SDK exception
│       ├── lyrics_client.dart         the one way out of the plugin
│       ├── lyrics_plugin.dart         identity, initialize, dispose
│       ├── matching.dart              the guard — read this one twice
│       ├── parsing/
│       │   ├── lrc_parser.dart        LRC and enhanced LRC
│       │   └── ttml_parser.dart       Apple-flavoured word-timed TTML
│       ├── providers/
│       │   └── lyrics_provider.dart   ranking, ordering, and when to throw
│       └── sources/
│           ├── lyrics_source.dart     found / none / failed, and why it matters
│           ├── lrclib_source.dart
│           └── betterlyrics_source.dart
└── test/                              113 tests, offline, real committed fixtures
```
