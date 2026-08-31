# Moving Visuals

`visuals` is a source-agnostic Swayve plugin. It accepts a complete
`SwayveTrack`, searches an external visual catalog, and returns the SDK's
`SwayveVisual` data model. The host remains responsible for choosing a
surface and playing the returned media.

## TIDAL provider

The first source is the official [TIDAL Developer Platform][tidal-api]. The
lookup uses documented JSON:API endpoints:

1. Search `/v2/searchResults` for the track and request `include=videos`.
2. If the search response does not compound the video resources, fetch the
   returned video identifiers from `/v2/videos`.
3. Request `/v2/videoManifests/{id}` with `uriScheme=HTTPS` and
   `usage=PLAYBACK`.
4. Return the manifest's HTTPS `link.href` as a `video` visual, provided its
   hostname is covered by `plugin.json`'s allowlist.

Every request goes through `SwayvePluginContext.http`; this plugin owns no
socket and has no `package:http`, `dio`, browser automation, HTML parser, or
page scraper. The official TIDAL API requires an OAuth bearer token. Configure
one in the plugin's secret `tidal_access_token` setting. It is read per lookup
and is never logged or copied into ordinary plugin storage.

The matcher is deliberately conservative: it requires a title match and,
when both durations are known, keeps the difference within 20 seconds. It
declines DRM manifests because the SDK visual contract currently carries no
DRM license data. It also declines an API response whose playable URL is not
HTTPS or is outside the manifest allowlist.

## Apple Music boundary

Apple Music is not enabled in this version. Apple documents catalog music-video
lookups, but access uses Apple Music API/MusicKit authorization and the
returned playable media contract is not equivalent to an unauthenticated page
URL. Adding a source adapter later is isolated behind `VisualsSource`; no
Apple page scraping or undocumented endpoint is used as a fallback today.

## Development

```text
dart pub get
dart format --output=none --set-exit-if-changed lib test
dart analyze
dart test
```

The test suite is offline and drives the provider with committed JSON:API
fixtures through the SDK fake HTTP client.

[tidal-api]: https://developer.tidal.com/documentation/api-sdk/api-sdk-authorization
