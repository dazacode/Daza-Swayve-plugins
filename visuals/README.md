# Moving Visuals

`visuals` is a source-agnostic Swayve plugin. It accepts a complete
`SwayveTrack`, searches an external visual catalog, and returns the SDK's
`SwayveVisual` data model. The host remains responsible for choosing a
surface and playing the returned media.

## What it looks for

A **moving cover** — scenery for the now-playing screen, not something anybody
navigates to. Two things qualify, and the plugin returns both as
`SwayveVisualKind.motionArtwork`:

- A **canvas**: the short portrait loop an artist attaches to one specific
  recording on Spotify. Reported at 9:16, the shape it was authored for.
- An **animated cover**: the sleeve with a few seconds of motion in it, which
  a label uploads alongside the still artwork. It is an album asset — every
  track on a release shares one. Reported at 1:1, because every cover TIDAL
  serves at this path is square.

A canvas is the more specific of the two — made for the song rather than the
release — which is why it is tried first when it is available at all.

It does **not** look for music videos any more. An earlier version resolved
`/v2/videoManifests` with `usage=PLAYBACK`, which was wrong on three counts:
a music video is a different thing from a moving cover, reaching that endpoint
needs the `playback` scope and therefore a subscriber authorisation flow this
plugin has no business running, and TIDAL restricts playback of its signed
HLS/DASH manifests to its own player SDK.

## Sources, in order

### 1. Spotify canvas — optional, off by default

Off until `spotify_sp_dc` is set, and silent when it is not: an unconfigured
source that announced itself would be noise for the large majority of people
who will never turn this on.

**It needs two credentials, not one.** `spotify_sp_dc` fetches the canvas;
`spotify_client_id` and `spotify_client_secret` — a free application
registered at developer.spotify.com — find the recording. Both are required,
and the split is not tidiness.

The canvas endpoint is keyed on a `spotify:track:…` URI, and the host never
hands a visuals provider an id from another catalogue, so the recording has to
be searched for. The obvious move was to search with the same web-player token
the canvas call already needs. That does not work: `api.spotify.com` answers a
web-player token with `429 API rate limit exceeded` on the first request and
every one after it, regardless of headers. The public Web API is not a door
that token opens.

The failure was maximally unhelpful — the account session worked, the canvas
endpoint worked, and the only broken step in between produced no URI, so the
plugin declined and reported "no canvas for this recording" with complete
confidence. Two credentials, each used where it is actually entitled, is the
fix. It also keeps the session cookie touching as little as possible:
searching a public catalogue is not something anybody's account needs to be
involved in, and the cookie is never minted at all for a song that could not
be found.

**What the session credential is.** `sp_dc` is a session cookie for a real Spotify
account, not an application credential like the TIDAL pair above it. Whoever
holds it can act as that account. Nothing in Swayve obtains one for you and
nothing prompts for it — a person who wants canvases copies it out of their
own browser knowingly. It is a `secret` setting, so it lives in the platform
credential store; it is never logged and never appears in an exception
message.

**Where it goes.** To `open.spotify.com`, once, to mint a short-lived access
token. The two requests that follow carry that token instead. The cookie
itself never reaches the search or canvas endpoints, and there is a test
asserting exactly that.

**How the lookup works.** Three requests:

1. `POST accounts.spotify.com/api/token` with the application credential, for
   the documented search below. Standard client-credentials, nothing unusual.
2. `GET open.spotify.com/api/token` with the cookie and a six-digit TOTP,
   which the web player's token endpoint now demands. The code is computed
   locally from a version-numbered constant compiled into the public web
   player — see `lib/src/spotify_totp.dart` for why that constant is embedded
   here rather than downloaded from one of the community mirrors, one of which
   Spotify had taken down in early 2026, breaking every client depending on it
   at once.
3. `GET api.spotify.com/v1/search` to resolve the recording to a
   `spotify:track:…` URI. The SDK never hands a visuals provider an id from
   somebody else's catalogue, so this hop is unavoidable; it is also where
   nearly all the risk of a wrong answer lives, which is why the result goes
   through the same conservative rules in `lib/src/matching.dart` that the
   TIDAL sources use, and why Spotify's own search rank contributes nothing to
   the score.
4. `POST spclient.wg.spotify.com/canvaz-cache/v0/canvases`, protobuf in and
   protobuf out. Both messages are small enough to encode and decode by hand;
   `lib/src/canvas_protobuf.dart` carries the schema. The live response
   carries fields the published schema does not mention, so the decoder skips
   what it does not recognise rather than refusing the message.

**A rejected cookie does not look like a rejection.** `open.spotify.com`
answers a bad `sp_dc` with `200` and a complete, valid, *anonymous* token —
the same one it gives a logged-out browser — and an anonymous session can see
no canvases at all. Accepting it meant every request afterwards succeeded and
returned nothing. The plugin checks `isAnonymous` and treats it as the auth
failure it is.

**Failures are raised, not swallowed.** An earlier version answered null on an
auth failure so the lookup could fall through to TIDAL. It falls through
either way — `SourceAgnosticVisualsProvider` only surfaces a failure when no
source produced anything — but answering null told the host "this recording
has no canvas", which it caches for ten minutes. Swayve deliberately declines
to cache a negative when a provider threw, precisely so that correcting a
setting takes effect without an app restart; swallowing the exception
re-created the restart-to-apply behaviour it had removed, and made the most
likely failure invisible.

**None of this is documented, and it will break.** The endpoints are internal
and the TOTP secret is rotated at Spotify's discretion. That is survivable
here in a way it would not be for a streaming source: when it breaks, this
source returns null, the two TIDAL sources behind it answer instead, and the
now-playing screen shows what it would have shown anyway. `spotify_totp_version`
exists so a rotation can be survived by typing a number rather than waiting
for a release.

**Most tracks have no canvas.** They are authored per release by the artist,
not generated, so a null answer here is the common case and not a fault.

### 2. Official TIDAL Developer Platform — optional

Used first when the plugin has been given TIDAL application credentials.
`tidal_client_id` and `tidal_client_secret` are `secret` settings; from them
the plugin mints a client-credentials bearer token at
`https://auth.tidal.com/v1/oauth2/token` and searches `/v2/searchResults`.

The plugin asks for an id and a secret rather than a ready-made access token
because a TIDAL access token expires within the day: a setting holding one
works until it silently stops. The minted token is held in memory only and is
never written to plugin storage — it is short-lived derived state, re-mintable
at any moment from settings that are stored.

Both settings are optional. With neither set, this source stands aside
silently rather than reporting a failure nobody asked to hear about.

### 3. TIDAL catalog search — no credentials

`GET https://api.tidal.com/v1/search` with `types=TRACKS,ALBUMS`, reading
`videoCover` from the album, then requesting

```text
https://resources.tidal.com/videos/{a}/{b}/{c}/{d}/{e}/1280x1280.mp4
```

where `{a}`–`{e}` are the cover id's five hyphen-separated groups.

**This is not a documented endpoint**, and the previous version of this README
promised there would never be one here. That promise is being broken
knowingly, and it is worth writing down why. The documented API cannot serve
this feature: its playback endpoints are scoped to subscriber sessions and
restricted to TIDAL's own player, and no unauthenticated documented route to
an animated cover exists. The alternative sources are worse rather than
better — Apple Music's motion artwork needs a web-player JWT scraped out of a
JavaScript bundle, and Spotify's canvas needs the listener's own account
cookie plus a rotating TOTP secret. Against those, a catalog search and a
static file on a public CDN is the smallest thing that works, which is why it
remains the source that carries this feature for almost everybody.

Spotify has since been added anyway, as source 1 below, and the two objections
above did not both survive. "A rotating TOTP secret fetched from a third
party" no longer applies: the secret is a constant in this repository and
nothing is fetched at runtime. "The listener's own account cookie" applies
exactly as stated, and is not solved — it is *accepted*, off by default, in
return for the one thing no other source can offer. Read the section below
before turning it on.

The `X-Tidal-Token` header this sends is a shared client token, not a
credential belonging to anybody. It grants no account access and carries no
user identity. It can be revoked at any time, which would disable this source
and leave the official one above unaffected.

## Boundaries that still hold

Every request goes through `SwayvePluginContext.http`. This plugin owns no
socket and has no `package:http`, `dio`, browser automation, HTML parser, or
page scraper. Nothing is scraped: every source is a JSON or protobuf API, and
the media is a plain progressive MP4.

The pubspec still declares exactly one dependency, the SDK, and the Spotify
source did not change that. Three things it needed would ordinarily have
arrived as packages and are vendored instead:

- **HMAC-SHA1** (`lib/src/hmac_sha1.dart`), rather than `package:crypto`. Two
  functions from RFC 3174 and RFC 2104, pinned in tests to the published
  vectors — a wrong HMAC would otherwise produce a well-formed six-digit
  number that simply gets refused, with nothing in the logs to say why.
- **Protobuf** (`lib/src/canvas_protobuf.dart`), rather than
  `package:protobuf` and a generator step, for two messages with six scalar
  fields between them.
- **TOTP** (`lib/src/spotify_totp.dart`), rather than an OTP package.

A plugin that pulls in its own packages is a plugin whose supply chain the
host cannot see, and that is a worse trade than a hundred lines of
well-specified arithmetic.

One deliberate exception to this plugin's usual honesty about itself: the
requests to `open.spotify.com` send a browser user-agent rather than
`Swayve-Visuals/…`. The token endpoint belongs to the web player rather than
to a documented API and refuses anything that does not look like a browser.
Declaring ourselves there would be more honest and would not work.

The matcher is deliberately conservative, and more so than the music-video
matcher it replaces. A wrong music video is a wrong video; a wrong animated
cover is the wrong *sleeve* moving behind the right song, which reads as a bug
rather than a near miss. So:

- an artist has to agree before anything else is considered;
- a tracks-shelf candidate must also match on title, and on duration within 20
  seconds when both are known;
- an albums-shelf candidate is accepted on an agreeing artist alone, but ranked
  below any track hit, and refused outright if the track named a *different*
  album;
- a cover id that is not five hexadecimal groups yields no visual rather than a
  guessed URL, since that id becomes a URL path;
- a media host outside `plugin.json`'s allowlist is refused;
- a Spotify hit must agree on title, artist *and* duration before its URI is
  looked up, and a canvas naming a different track than the one asked about is
  discarded rather than shown.

## Apple Music

Removed. It was never enabled: catalog music-video access uses Apple Music
API/MusicKit authorization, whose returned media contract is not equivalent to
an unauthenticated URL, and the developer token behind it needs a paid Apple
Developer Program membership. Adding a source later is still isolated behind
`VisualsSource`.

## Development

```text
dart pub get
dart format --output=none --set-exit-if-changed lib test
dart analyze
dart test
```

The test suite is offline and drives the client and provider with committed
fixtures through the SDK fake HTTP client.

[tidal-api]: https://developer.tidal.com/documentation/api-sdk/api-sdk-authorization
