import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

import '../ids.dart';
import 'track_parser.dart';

/// Parses a SoundCloud related-track page into station tracks.
///
/// Related responses normally contain bare track objects, but the web API has
/// also used the same `{"track": {...}}` wrapper as charts and activity feeds.
/// The seed and duplicate rows are removed so the first radio page cannot
/// immediately replay what it was seeded from.
List<SwayveTrack> parseRadioTrackList(
  Iterable<Object?> items, {
  required int seedId,
}) {
  final List<SwayveTrack> tracks = <SwayveTrack>[];
  final Set<int> seen = <int>{seedId};
  for (final Object? item in items) {
    final Map<String, Object?> json = unwrapChartItem(item);
    final SwayveTrack? track = parseTrack(json);
    if (track == null) continue;
    final int? id = SoundCloudIds.numericValue(track.id);
    if (id == null || !seen.add(id)) continue;
    tracks.add(track);
  }
  return tracks;
}
