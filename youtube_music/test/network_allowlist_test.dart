import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:swayve_plugin_sdk/testing.dart';
import 'package:test/test.dart';
import 'package:youtube_music/youtube_music.dart';

import 'support.dart';

/// The test that proves the plugin honours its own declaration.
///
/// `network.hosts` is what the user is shown and what the host enforces. It is
/// only meaningful if the plugin never tries to reach past it — and "never
/// tries" has to be demonstrated, not asserted in a README. So: exercise every
/// provider, then check every recorded request, and every URL handed onward
/// for the host to fetch, against the hostnames the manifest itself declares.
///
/// The allowlist used here is read from `plugin.json` rather than from the
/// plugin's own `kYouTubeMusicAllowedHosts`. Asking the plugin whether the
/// plugin is behaving would prove nothing.
void main() {
  test('the manifest actually declares hosts', () {
    expect(manifestHosts, isNotEmpty);
    expect(
      manifestPermissions,
      contains(SwayvePermission.network),
      reason: 'A hosts list without the network permission is decoration.',
    );
  });

  test('every outbound request targets a declared host', () async {
    final PluginHarness harness = await PluginHarness.start();
    addTearDown(harness.stop);

    // Search.
    harness.http.enqueueJson(fixture('search_all.json'));
    await harness.search.search(const SwayveSearchQuery(text: 'aster vale'));

    // Every catalogue listing.
    for (final SwayveSortOrder sort in SwayveSortOrder.values) {
      harness.http.enqueueJson(fixture('browse_home.json'));
      await harness.catalog.albums(SwayveBrowseRequest(sort: sort));
    }
    harness.http.enqueueJson(fixture('browse_home.json'));
    await harness.catalog.artists(SwayveBrowseRequest.first);
    harness.http.enqueueJson(fixture('browse_home.json'));
    await harness.catalog.tracks(SwayveBrowseRequest.first);

    // Detail lookups.
    harness.http.enqueueJson(fixture('browse_album.json'));
    await harness.catalog.album(
      YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
    );
    harness.http.enqueueJson(fixture('browse_artist.json'));
    await harness.catalog.artist(
      YouTubeMusicIds.mediaId('UCq3rGZ1Zs9d0dTqRPcJHXyA'),
    );
    harness.http.enqueueJson(fixture('browse_album.json'));
    await harness.catalog.albumTracks(
      YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
    );

    // Artwork for every kind that needs a request.
    harness.http.enqueueJson(fixture('browse_album.json'));
    await harness.artwork.artwork(
      YouTubeMusicIds.mediaId('MPREb_9nqEki4ZLqI'),
    );
    harness.http.enqueueJson(fixture('browse_artist.json'));
    await harness.artwork.artwork(
      YouTubeMusicIds.mediaId('UCq3rGZ1Zs9d0dTqRPcJHXyA'),
    );
    harness.http.enqueueJson(fixture('browse_home.json'));
    await harness.artwork.artwork(
      YouTubeMusicIds.mediaId('VLPLZ4mM3wKuMh8'),
    );

    expect(
      harness.http.requests,
      isNotEmpty,
      reason: 'A test that recorded nothing proves nothing.',
    );
    for (final RecordedHttpRequest request in harness.http.requests) {
      expect(
        request.url.scheme,
        'https',
        reason: 'Plaintext for ${request.url}.',
      );
      expect(
        manifestAllowsHost(request.url.host),
        isTrue,
        reason: '${request.url.host} is not in plugin.json network.hosts '
            '($manifestHosts). Request: ${request.method} ${request.url}',
      );
    }
  });

  test('every URL handed to the host is on a declared host', () async {
    final PluginHarness harness = await PluginHarness.start();
    addTearDown(harness.stop);

    final List<Uri> surfaced = <Uri>[];

    harness.http.enqueueJson(fixture('search_all.json'));
    final SwayveSearchResult result = await harness.search.search(
      const SwayveSearchQuery(text: 'aster vale'),
    );
    for (final SwayveTrack track in result.tracks) {
      if (track.artwork != null) surfaced.add(track.artwork!.uri);
    }
    for (final SwayveAlbum album in result.albums) {
      if (album.artwork != null) surfaced.add(album.artwork!.uri);
    }
    for (final SwayveArtist artist in result.artists) {
      if (artist.image != null) surfaced.add(artist.image!.uri);
    }

    for (final SwayveArtworkSize size in SwayveArtworkSize.values) {
      final SwayveImageRef? image = await harness.artwork.artwork(
        YouTubeMusicIds.mediaId('kJQP7kiw5Fk'),
        size: size,
      );
      if (image != null) surfaced.add(image.uri);
    }

    // Both playback answers, because they surface different hosts: the embed
    // is a page on youtube.com and the audio is a media server chosen by
    // YouTube at resolve time. The second is the one this test exists for.
    final SwayvePlayableSource embed = await harness.stream.resolvePlayback(
      YouTubeMusicIds.mediaId('kJQP7kiw5Fk'),
      hints: const SwayvePlaybackHints(preferAudioOnly: false),
    );
    surfaced.add(embed.embed!.uri);

    harness.http
      ..enqueueJson(fixture('player_visitor_id.json'))
      ..enqueueJson(fixture('player_ok.json'));
    final SwayvePlayableSource audio = await harness.stream.resolvePlayback(
      YouTubeMusicIds.mediaId('kJQP7kiw5Fk'),
    );
    surfaced.add(audio.uri!);

    expect(surfaced, isNotEmpty);
    for (final Uri uri in surfaced) {
      expect(
        manifestAllowsHost(uri.host),
        isTrue,
        reason: '$uri is outside plugin.json network.hosts ($manifestHosts). '
            'The host fetches these through the same restricted client.',
      );
    }
  });

  test('the plugin refuses to build a URL off the allowlist', () {
    for (final String host in manifestHosts) {
      expect(isAllowedHost(host), isTrue);
      expect(isAllowedHost(host.toUpperCase()), isTrue);
    }
    for (final String host in <String>[
      // `lh3.googleusercontent.com` used to be here, as the example of a host
      // the plugin could see referenced and was not permitted to reach. It is
      // declared now — it is where the square cover art lives — so what proves
      // the rule is the neighbours below, which are all still refused.
      'evil.example.com',
      'music.youtube.com.evil.example.com',
      'youtube.com',
      '',
    ]) {
      expect(
        isAllowedHost(host),
        isFalse,
        reason: '$host must not be treated as declared.',
      );
    }
  });
}
