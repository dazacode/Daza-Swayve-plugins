# Example Plugin

The reference Swayve plugin. Its job is to be **read**, not to be useful.

It contributes a handful of invented tracks, albums and artists to Swayve's
search and browsing surfaces, and that is all it does. No network, no storage,
no credentials, no web view, no playback — which is exactly what makes it a
good first read. Everything that is left in the file is the shape of a plugin.

```
plugins/example/
├── plugin.json                 the manifest: what it can do, what it needs
├── pubspec.yaml                one dependency: the SDK
├── lib/example.dart            the entrypoint and the lifecycle
├── lib/src/catalogue.dart      the data, and normalization at the boundary
├── lib/src/providers.dart      search and catalog, with cancellation + paging
├── test/                       what all of the above is supposed to do
└── licenses/                   Apache-2.0 and the third-party notice
```

Read it in that order. It is about 300 lines of code and roughly as many lines
of commentary; you can finish it in one sitting.

## Running it

```bash
cd plugins/example
dart pub get
dart analyze          # zero issues
dart test             # 29 tests, no sockets, no Flutter
```

From the repository root:

```bash
dart run tools/validate_plugin.dart plugins/example
dart test --directory plugins/example
```

There is no way to run it inside Swayve yet. The client has no plugin loader —
see [`docs/host-integration.md`](../../docs/host-integration.md) for the work
that is still required on the host side. The SDK's fakes are what let this
plugin be developed and proven in the meantime, and that is deliberate: a
plugin you can only test by installing the app is a plugin nobody will test.

## What it declares

| Field | Value | Why |
|---|---|---|
| `capabilities` | `search`, `catalog` | Two capabilities, so two providers get registered — `SwayveSearchProvider` and `SwayveCatalogProvider`, and nothing else. |
| `permissions` | *(empty)* | It reads a constant compiled into itself. No host, no disk, no socket. |
| `runtime` | `compiled` | Its source lives in this repository and is built into Swayve. |
| `platforms` | all five | Nothing here is platform-specific. |
| `media.streamable` | `false` | It resolves no playback. |
| `media.downloadable` | `false` | It has no files to hand over. |

### Why `permissions` is empty

Because it is true. `capabilities` must be non-empty — a plugin that answers
no questions is not a plugin — but `permissions` may be empty, and a plugin
that asks for `network` "just in case" costs the user a permission prompt for
a facility it never touches. Over-permissioning is precisely the failure the
permission model exists to make visible, and the reference plugin should not
be the first example of it.

`test/permission_guard_test.dart` proves the claim rather than asserting it in
prose: it runs the whole lifecycle plus a search and every catalog method
against a `FakeSwayvePluginContext` with **nothing** granted, and the fake
enforces that set through the same mixin the host uses. If a later edit adds
an HTTP call, that test fails before the change reaches anyone's phone.

### Why it claims no playback

`media.streamable` and `media.downloadable` are both `false`, every track's
`availability` is `SwayveAvailability.none`, and there is no
`SwayveStreamProvider` anywhere in the package.

This is the point worth taking away: **a plugin may contribute catalogue data
without claiming any playback rights.** Streamable, downloadable and on-device
are three independent facts (spec §17), and none of them follows from "this
plugin knows about this track". A metadata source, a lyrics provider or a
recommendation engine has plenty to contribute and nothing to play, and the
manifest, the models and the registered providers must all say so
consistently — because the host believes them. A plugin that overstates
`availability` does not get caught by a validator; it gets caught by a user
pressing play on something that cannot play.

## The eight things this plugin is trying to teach

1. **The lifecycle.** `load → initialize → registerProviders → active →
   dispose`. The entrypoint function is cheap and synchronous; `initialize`
   registers and returns; `dispose` is idempotent and does not touch the
   network.
2. **Why providers are registered in `initialize`.** It is how the host learns
   what a plugin can do without knowing what a plugin *is*. There is no
   `if (plugin.id == 'example')` anywhere in Swayve, and there is nowhere for
   one to go.
3. **Why a plugin never renders UI.** Plugins supply data; the host draws it.
   That is why the SDK is pure Dart with no Flutter dependency — a plugin that
   could inject widgets could break the app's layout, theme, accessibility and
   frame budget, and "a broken plugin must never break Swayve" is the
   principle the whole design is bent around.
4. **Normalization happens at the plugin's boundary.** `lib/src/catalogue.dart`
   holds records shaped the way real music APIs are shaped — a credit as one
   string, a duration as an integer — and converts them into SDK models before
   anything else sees them. That single conversion point is what lets the host
   render every provider's data identically.
5. **`extra` carries provider-specific data the host must not interpret.**
   The host carries it, persists it and hands it back untouched. Use it to
   save yourself a lookup; never use it to smuggle in something the host is
   supposed to act on, because the moment the host read it, it would have to
   know which plugin wrote it.
6. **Cancellation is checked inside the loop, not only before it.** A
   cooperative provider stops when asked instead of finishing a scan the host
   stopped caring about. `_withinOperationDeadline` in `providers.dart` shows
   the other half — a plugin that notices its own overrun reports
   `SwayvePluginTimeoutException`, which is a more accurate thing for Swayve
   to show a user than the `SwayvePluginUnavailableException` the host would
   have to invent when its own deadline fires.
7. **Failures are `SwayvePluginException` subtypes, never raw throws.** The
   host isolates a raw throw too, but it cannot interpret one, so an unknown
   error can only become a generic "temporarily unavailable".
8. **Not-found is a value, not a failure.** `ExampleCatalogProvider.album`
   returns `null` for an id that is not in the catalogue and for an id another
   plugin minted. An empty search result means "I searched and there was
   nothing"; an exception would mean "this source is down", and Swayve shows
   those two very differently.

## Deliberate omissions

Things a real plugin would have that this one does not, so you are not
surprised by their absence:

- **No artwork.** There is no `SwayveArtworkProvider` and every `artwork` field
  is `null` — with no network and no bundled assets there is no honest image to
  point at, and a `SwayveImageRef` to a URL that 404s is worse than none.
- **No settings.** No `settings` block in the manifest, so nothing for the host
  to render. Note that the host renders settings UI, always; a plugin never
  draws its own settings page.
- **No search cursor.** The whole catalogue fits in one response, so search
  returns `cursor: null`. Browsing *does* page, because that is where the
  cursor contract is worth demonstrating.
- **No `network.hosts`.** It makes no outbound requests, so there is nothing to
  declare and no `network` permission to declare it under.

## Copying it

`plugins/example` is the supported starting point — there is no scaffolding
generator. Copy the directory, then change three things in `plugin.json`
before anything else:

```jsonc
{
  "id": "dev.yourname.swayve.my_plugin",  // reverse-DNS, at least 3 segments
  "entrypoint": "my_plugin",              // MUST equal the directory name
  "name": "My Plugin"
}
```

Then rename the entrypoint function in `lib/`, update `examplePluginId`, and
run the validator. Forgetting to rename the directory *or* the `entrypoint` is
the most common first failure, and the validator names it precisely.

Do not carry the fixture catalogue forward. Replace `lib/src/catalogue.dart`
with a client for whatever you are actually integrating, keep the shape — raw
in, normalized out, at the boundary — and the providers above it should barely
need to change.
