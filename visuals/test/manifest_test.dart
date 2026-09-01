import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:visuals/visuals.dart';

/// The gate that makes the compiled manifest safe to duplicate.
///
/// `lib/src/manifest.dart` exists so a host can refresh a stored manifest
/// from the code it just installed, which means it is a second copy of
/// `plugin.json`. A second copy is only acceptable while something fails the
/// moment the two disagree — otherwise the host would confidently refresh a
/// stored row to a manifest that no longer describes this plugin, which is
/// worse than the staleness it set out to fix.
void main() {
  final Object? onDisk = jsonDecode(File('plugin.json').readAsStringSync());

  test('the compiled manifest is the file, entire', () {
    expect(visualsPluginManifest(), onDisk);
  });

  test('it agrees with the constants the plugin is built from', () {
    final manifest = visualsPluginManifest();
    expect(manifest['id'], kVisualsPluginId);
    expect(manifest['name'], kVisualsPluginName);
    expect(manifest['version'], kVisualsPluginVersion.toString());
    expect(manifest['network'], <String, Object?>{
      'hosts': kVisualsAllowedHosts,
    });
  });

  test('it declares the settings the Spotify source reads', () {
    // The specific failure this whole file exists to prevent: the code reads
    // a setting the manifest never declared, so the host renders no field and
    // the source stands aside forever.
    final settings = (visualsPluginManifest()['settings']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final ids = settings.map((s) => s['id']).toSet();
    expect(ids, contains(kSpotifySpDcSettingId));
    expect(ids, contains(kSpotifyTotpVersionSettingId));
    expect(ids, contains(kTidalClientIdSettingId));
    expect(ids, contains(kTidalClientSecretSettingId));

    // The cookie must be a secret, not a plain string: it is a live session
    // credential and belongs in the platform credential store.
    final spDc = settings.firstWhere((s) => s['id'] == kSpotifySpDcSettingId);
    expect(spDc['type'], 'secret');
  });
}
