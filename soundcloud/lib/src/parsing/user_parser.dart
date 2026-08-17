import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../ids.dart';
import '../json_path.dart';
import 'artwork.dart';

/// Turns one SoundCloud `user` object into a [SwayveArtist], or `null` when
/// [json] does not have the minimum shape of one (an id and a username).
SwayveArtist? parseArtist(Map<String, Object?> json) {
  final int? id = intAt(json, ['id']);
  final String? username = stringAt(json, ['username']);
  if (id == null || username == null) return null;

  return SwayveArtist(
    id: SoundCloudIds.user(id),
    name: username,
    image: SoundCloudArtwork.build(
      stringAt(json, ['avatar_url']),
      SwayveArtworkSize.medium,
    ),
    extra: <String, Object?>{
      if (stringAt(json, ['permalink_url']) case final String url) 'permalinkUrl': url,
      if (stringAt(json, ['city']) case final String city) 'city': city,
      if (stringAt(json, ['country_code']) case final String cc) 'countryCode': cc,
      if (intAt(json, ['followers_count']) case final int count) 'followersCount': count,
      if (boolAt(json, ['verified']) case final bool verified when verified) 'verified': true,
    },
  );
}

/// Parses every well-formed user object in [items], skipping anything that
/// is not one rather than failing the whole list.
List<SwayveArtist> parseArtistList(Iterable<Object?> items) {
  final List<SwayveArtist> artists = <SwayveArtist>[];
  for (final Object? item in items) {
    final Map<String, Object?> json = mapOf(item);
    if (json.isEmpty) continue;
    final SwayveArtist? artist = parseArtist(json);
    if (artist != null) artists.add(artist);
  }
  return artists;
}
