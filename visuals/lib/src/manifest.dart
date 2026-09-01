/// This plugin's own `plugin.json`, compiled in.
///
/// ## Why a copy of a file that is right there
///
/// A `runtime: compiled` plugin's Dart code is linked into the host binary at
/// build time, but its manifest reaches the host a completely different way:
/// through a `.swayveplugin` bundle the host imported once and snapshotted
/// into its database. Those two halves then age independently. A host that
/// updates picks up new plugin *code* while still holding the manifest it
/// stored months earlier — so a setting added here would exist in the code,
/// be read by `initialize`, and have no field on screen to put a value in,
/// because the stored manifest never heard of it.
///
/// The manifest cannot simply be read off disk at runtime: this package
/// arrives as a git dependency, and nothing outside `lib/` is reachable from
/// a Flutter app. So the host needs it as Dart, and this is that.
///
/// It is a duplicate, and duplicates drift. This one cannot: `manifest_test`
/// parses both and fails if they differ by so much as a key.
library;

import 'dart:convert';

/// The manifest text, byte-identical to `plugin.json`.
const String kVisualsPluginManifestJson = r'''
{
  "schemaVersion": 7,
  "id": "app.swayve.plugins.visuals",
  "name": "Moving Visuals",
  "description": "Finds the moving cover for whatever is playing: Spotify's canvas when a session cookie is provided, otherwise the official animated cover matched against TIDAL's catalog.",
  "version": "0.1.0",
  "author": {
    "name": "Swayve",
    "url": "https://github.com/dazacode/swayve-plugins"
  },
  "license": "Apache-2.0",
  "homepage": "https://github.com/dazacode/Daza-Swayve-plugins/tree/main/visuals",
  "repository": "https://github.com/dazacode/Daza-Swayve-plugins",
  "swayvePluginApi": 1,
  "minimumSwayveVersion": "0.1.0",
  "runtime": "compiled",
  "platforms": [
    "android",
    "ios",
    "windows",
    "linux",
    "macos"
  ],
  "capabilities": [
    "visuals"
  ],
  "permissions": [
    "network",
    "external_auth"
  ],
  "entrypoint": "visuals",
  "media": {
    "streamable": false,
    "downloadable": false,
    "offlineCache": false
  },
  "network": {
    "hosts": [
      "openapi.tidal.com",
      "*.tidal.com",
      "open.spotify.com",
      "accounts.spotify.com",
      "api.spotify.com",
      "spclient.wg.spotify.com",
      "*.scdn.co"
    ]
  },
  "settings": [
    {
      "id": "tidal_client_id",
      "type": "secret",
      "label": "TIDAL client id",
      "description": "Optional. The client id of an application registered on the TIDAL developer portal. Animated covers are found without it; adding it asks the official API first."
    },
    {
      "id": "tidal_client_secret",
      "type": "secret",
      "label": "TIDAL client secret",
      "description": "Optional, and required only alongside the client id. Stored as a secret and never logged."
    },
    {
      "id": "spotify_sp_dc",
      "type": "secret",
      "label": "Spotify sp_dc cookie",
      "description": "The sp_dc cookie from a browser signed in to Spotify. Unlocks canvases. Stored as a secret, sent only to open.spotify.com. Leave empty for TIDAL covers."
    },
    {
      "id": "spotify_client_id",
      "type": "secret",
      "label": "Spotify client id",
      "description": "Required for canvases, alongside the cookie. A Spotify application registered free at developer.spotify.com; it finds the recording."
    },
    {
      "id": "spotify_client_secret",
      "type": "secret",
      "label": "Spotify client secret",
      "description": "The other half of the Spotify application credential. Stored as a secret and never logged."
    },
    {
      "id": "spotify_totp_version",
      "type": "string",
      "label": "Spotify TOTP version",
      "description": "Advanced. The current version is built in; set a number here only if canvases stop working and a newer one is known."
    }
  ],
  "timeouts": {
    "requestMs": 10000,
    "operationMs": 20000
  },
  "keywords": [
    "visuals",
    "canvas",
    "animated-cover",
    "motion-artwork",
    "tidal",
    "spotify"
  ],
  "icon": "assets/icon.svg"
}
''';

/// The manifest, decoded.
///
/// Decoded on each call rather than held in a `final`: the host reads this
/// once at startup to refresh a stored row, and a lazily-initialised static
/// would keep the parsed map alive for the life of the process to save a
/// parse nobody repeats.
Map<String, Object?> visualsPluginManifest() =>
    jsonDecode(kVisualsPluginManifestJson) as Map<String, Object?>;
