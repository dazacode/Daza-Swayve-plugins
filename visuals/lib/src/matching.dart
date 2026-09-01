/// Deciding whether two catalogues are describing the same recording.
///
/// Extracted from `tidal_client.dart` when a second source arrived. Both
/// sources face the identical problem — the host hands over a title, a credit
/// and a running time, and a service answers with its own spelling of the
/// same things — and two private copies of "close enough" would have drifted
/// apart, which for a visuals plugin means one source quietly accepting a
/// match the other rejects and the background changing depending on which
/// answered first.
///
/// The bar is deliberately high everywhere it is applied. The wrong video
/// behind a song is worse than no video, and the host's own artwork is a
/// better fallback than a near miss — the SDK says so in
/// `SwayveVisualsProvider.visual`, and these thresholds are how this plugin
/// keeps that promise.
library;

/// A conservative match window for audio and music-video durations.
///
/// Kept here rather than in `config.dart` because it is part of what "the
/// same recording" means, not a tunable.
const Duration kMatchDurationTolerance = Duration(seconds: 20);

/// Strips a title down to the words worth comparing.
///
/// Parenthesised and bracketed trailers go first — `(Remastered 2011)`,
/// `[Explicit]`, `(feat. …)` — because they are exactly what two catalogues
/// disagree about while naming the same recording. What is left is lowercased
/// and reduced to alphanumeric words.
String normalizeForMatch(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r'\([^)]*\)|\[[^\]]*\]'), ' ')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

/// The Jaccard overlap of the words in [left] and [right], from 0 to 1.
///
/// Word-set rather than sequence based, so word order and a dropped article
/// do not sink an otherwise exact match.
double tokenOverlap(String left, String right) {
  final Set<String> a =
      left.split(' ').where((String s) => s.isNotEmpty).toSet();
  final Set<String> b =
      right.split(' ').where((String s) => s.isNotEmpty).toSet();
  if (a.isEmpty || b.isEmpty) return 0;
  return a.intersection(b).length / a.union(b).length;
}

/// Whether [candidate] names the same title as [wanted].
///
/// Both are normalized here, so callers pass raw titles. Containment counts
/// because one catalogue's `Song` is routinely another's `Song - Radio Edit`
/// once the bracketed form has been stripped; below that, seven words in ten
/// have to agree.
bool titlesAgree(String wanted, String candidate) {
  final String a = normalizeForMatch(wanted);
  final String b = normalizeForMatch(candidate);
  if (a.isEmpty || b.isEmpty) return false;
  return a == b || a.contains(b) || b.contains(a) || tokenOverlap(a, b) >= 0.7;
}

/// Whether any of [candidates] names the same artist as [wanted].
///
/// Looser than [titlesAgree] at half the words, because a credit is where
/// catalogues disagree most: featured artists, `&` against `and`, a duo
/// credited jointly on one service and separately on another.
bool artistsAgree(String wanted, Iterable<String> candidates) {
  final String a = normalizeForMatch(wanted);
  if (a.isEmpty) return true;
  for (final String candidate in candidates) {
    final String b = normalizeForMatch(candidate);
    if (b.isEmpty) continue;
    if (a == b || a.contains(b) || b.contains(a) || tokenOverlap(a, b) >= 0.5) {
      return true;
    }
  }
  return false;
}

/// Whether two running times are close enough to be the same recording.
///
/// A null on either side is not a disagreement: plenty of catalogues report
/// no duration, and refusing every one of them would throw away more correct
/// matches than the check saves.
bool durationsAgree(
  Duration? wanted,
  Duration? candidate, {
  Duration tolerance = kMatchDurationTolerance,
}) {
  if (wanted == null || candidate == null) return true;
  return (wanted - candidate).abs() <= tolerance;
}
