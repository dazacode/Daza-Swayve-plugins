/// Navigation helpers for InnerTube's deeply nested renderer trees.
///
/// Spec §19 says a raw exception must never escape a provider method. The
/// failure mode these helpers exist to prevent is the boring one: a response
/// changes shape, a cast throws `TypeError`, and the host sees an error it
/// cannot classify instead of `SwayvePluginMalformedResponseException`.
///
/// The rule the whole parser follows is therefore:
///
/// * **navigating is total.** [dig], [mapOf], [listOf] and the scalar readers
///   return `null` or an empty collection for anything unexpected — a missing
///   key, a string where an object was, a list index past the end. They never
///   throw.
/// * **deciding is where it fails.** When the parser has looked and found that
///   the payload is not a search response at all, it calls [malformedResponse]
///   deliberately.
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
      'YouTube Music: $message',
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

/// The integer at [path] under [node], or `null`.
///
/// Accepts a whole-valued double, because JSON numbers survive some round
/// trips as doubles.
int? intAt(Object? node, List<Object> path) {
  final Object? value = dig(node, path);
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  return null;
}

/// The concatenated `text` of a `runs` array at [path] under [node].
///
/// InnerTube splits a display string into runs so that individual words can
/// carry navigation endpoints; joining them back is how you recover the label
/// a user would read.
String? runsTextAt(Object? node, List<Object> path) {
  final List<Object?> runs = listAt(node, path);
  if (runs.isEmpty) {
    // A few renderers use `simpleText` instead of `runs` for a static label.
    return stringAt(node, <Object>[
      ...path.take(path.length - 1),
      'simpleText',
    ]);
  }
  final StringBuffer buffer = StringBuffer();
  for (final Object? run in runs) {
    final String? text = stringAt(run, const <Object>['text']);
    if (text != null) buffer.write(text);
  }
  final String text = buffer.toString();
  return text.isEmpty ? null : text;
}

/// Parses a `m:ss` or `h:mm:ss` duration label, or returns `null`.
///
/// YouTube Music writes durations as display text, so this is the only place
/// a track length can come from without a second request.
Duration? parseClockDuration(String? label) {
  if (label == null) return null;
  final List<String> parts = label.trim().split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  final List<int> values = <int>[];
  for (final String part in parts) {
    final int? value = int.tryParse(part.trim());
    if (value == null || value < 0) return null;
    values.add(value);
  }
  if (values.length == 2) {
    return Duration(minutes: values[0], seconds: values[1]);
  }
  return Duration(hours: values[0], minutes: values[1], seconds: values[2]);
}
