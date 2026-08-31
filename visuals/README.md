# Moving Visuals

`visuals` is a source-agnostic Swayve plugin. It accepts a complete
`SwayveTrack`, searches an external visual catalog, and returns the SDK's
`SwayveVisual` data model. The host remains responsible for choosing a
surface and playing the returned media.

## What it looks for

An **animated cover**: the sleeve with a few seconds of motion in it, which a
label uploads alongside the still artwork. It is an album asset — every track
on a release shares one — and it is what belongs behind a now-playing screen.
The plugin returns it as `SwayveVisualKind.motionArtwork` with an aspect ratio
of 1, because every cover TIDAL serves at this path is square.

It does **not** look for music videos any more. An earlier version resolved
`/v2/videoManifests` with `usage=PLAYBACK`, which was wrong on three counts:
a music video is a different thing from a moving cover, reaching that endpoint
needs the `playback` scope and therefore a subscriber authorisation flow this
plugin has no business running, and TIDAL restricts playback of its signed
HLS/DASH manifests to its own player SDK.

## Sources, in order

### 1. Official TIDAL Developer Platform — optional

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

### 2. TIDAL catalog search — no credentials

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
JavaScript bundle, and Spotify Canvas needs the listener's own account cookie
plus a rotating TOTP secret fetched from a third party. Against those, a
catalog search and a static file on a public CDN is the smallest thing that
works.

The `X-Tidal-Token` header this sends is a shared client token, not a
credential belonging to anybody. It grants no account access and carries no
user identity. It can be revoked at any time, which would disable this source
and leave the official one above unaffected.

## Boundaries that still hold

Every request goes through `SwayvePluginContext.http`. This plugin owns no
socket and has no `package:http`, `dio`, browser automation, HTML parser, or
page scraper. Nothing is scraped: both sources are JSON APIs, and the media is
a plain progressive MP4.

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
- a media host outside `plugin.json`'s allowlist is refused.

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
