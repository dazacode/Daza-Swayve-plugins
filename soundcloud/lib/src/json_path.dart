/// Navigation helpers for SoundCloud's JSON responses.
///
/// Spec §19 says a raw exception must never escape a provider method. The
/// failure mode these helpers exist to prevent is the boring one: a response
/// changes shape, a cast throws `TypeError`, and the host sees an error it
/// cannot classify instead of `SwayvePluginMalformedResponseException`.
///
/// SoundCloud's JSON is mostly flat compared to InnerTube's renderer trees,
/// but the same rule still applies and is followed for the same reason —
/// especially for the two shapes this plugin has not verified against live
/// traffic (`/playlists/discovery`'s exact envelope, and whichever of a
/// track's alternate field spellings SoundCloud is currently emitting):
///
/// * **navigating is total.** [dig], [mapOf], [listOf] and the scalar readers
///   return `null` or an empty collection for anything unexpected — a missing
///   key, a string where an object was, a list index past the end. They never
///   throw.
/// * **deciding is where it fails.** When the parser has looked and found
///   that the payload is not the kind of response it asked for, it calls
///   [malformedResponse] deliberately.
///
/// That split is what lets a single renamed field degrade one item instead of
/// failing the whole call, while a genuinely unrecognisable body still fails
/// loudly.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// Reports a payload this plugin cannot interpret.
///
/// Never returns. Use it at the point where the parser has established the
/// body is not the document it asked for — not on the first missing field.
Never malformedResponse(String message, [Object? cause]) =>
    throw SwayvePluginMalformedResponseException(
      'SoundCloud: $message',
      cause: cause,
    );

/// Walks [node] along [path], returning `null` the moment the shape stops
/// matching.
///
/// A `String` step indexes a JSON object; an `int` step indexes a JSON array.
/// Any other combination yields `null` rather than an error, so a caller may
/// probe several candidate shapes without a try/catch around each one.
Object? dig(Object? node, List<Object> path) {
  Object? current = node;
  for (final Object step in path) {
    if (current == null) return null;
    if (step is String) {
      if (current is! Map) return null;
      current = current[step];
    } else if (step is int) {
      if (current is! List || step < 0 || step >= current.length) return null;
      current = current[step];
    } else {
      return null;
    }
  }
  return current;
}

/// [node] as a JSON object, or an empty map when it is anything else.
Map<String, Object?> mapOf(Object? node) {
  if (node is Map<String, Object?>) return node;
  if (node is Map) {
    final Map<String, Object?> result = <String, Object?>{};
    for (final MapEntry<Object?, Object?> entry in node.entries) {
      final Object? key = entry.key;
      if (key is String) result[key] = entry.value;
    }
    return result;
  }
  return const <String, Object?>{};
}

/// [node] as a JSON array, or an empty list when it is anything else.
List<Object?> listOf(Object? node) =>
    node is List<Object?> ? node : const <Object?>[];

/// The JSON array at [path] under [node], or an empty list.
List<Object?> listAt(Object? node, List<Object> path) =>
    listOf(dig(node, path));

/// The JSON object at [path] under [node], or an empty map.
Map<String, Object?> mapAt(Object? node, List<Object> path) =>
    mapOf(dig(node, path));

/// The string at [path] under [node], or `null`.
String? stringAt(Object? node, List<Object> path) {
  final Object? value = dig(node, path);
  return value is String ? value : null;
}

/// The boolean at [path] under [node], defaulting to [orElse] when absent or
/// of the wrong type.
bool boolAt(Object? node, List<Object> path, {bool orElse = false}) {
  final Object? value = dig(node, path);
  return value is bool ? value : orElse;
}

/// The integer at [path] under [node], or `null`.
///
/// Accepts a whole-valued double and a numeric string, because JSON numbers
/// survive some round trips as doubles and SoundCloud's own ids have been
/// observed serialized both ways across endpoints.
int? intAt(Object? node, List<Object> path) {
  final Object? value = dig(node, path);
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  if (value is String) return int.tryParse(value);
  return null;
}

/// The double at [path] under [node], or `null`.
double? doubleAt(Object? node, List<Object> path) {
  final Object? value = dig(node, path);
  if (value is num) return value.toDouble();
  return null;
}
