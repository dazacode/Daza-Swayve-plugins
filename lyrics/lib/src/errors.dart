/// The single place a failure becomes a `SwayvePluginException`.
///
/// Spec §19: a provider method must complete, honour cancellation, or throw
/// one of the SDK's exceptions — never anything else. The one public provider
/// method in this plugin is therefore wrapped in [runGuarded], and every
/// non-2xx response a source decides it cannot live with goes through
/// [throwForStatus]. Nothing else here throws on purpose.
///
/// The word "decides" is doing real work in that sentence. A lyrics plugin
/// meets far more non-2xx responses than a catalogue plugin does, and almost
/// none of them are failures: LRCLIB answers `404` for every recording nobody
/// has transcribed, and BetterLyrics answers `401` for every recording that is
/// not already in the cache it serves anonymous callers from. Those are
/// answers, not errors, and the sources read them before anything in this file
/// is reached. See `sources/lyrics_source.dart` for how a source says "I have
/// nothing" in a way that stays distinguishable from "I am broken", and why
/// that distinction is what decides whether the whole call throws.
library;

import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// Runs [body] as one provider operation.
///
/// It enforces the three things the contract asks of every provider call:
///
/// * **cancellation** — checked before any work starts, and raced against the
///   work afterwards, so a host that has skipped to the next song is not made
///   to wait for an in-flight lookup of the previous one;
/// * **the deadline** — [timeout] is the manifest's `timeouts.operationMs`,
///   covering the whole operation including every source asked, and a breach
///   surfaces as `SwayvePluginTimeoutException`;
/// * **error isolation** — a `SwayvePluginException` passes through unchanged,
///   and anything else becomes `SwayvePluginUnavailableException` rather than
///   escaping as itself.
///
/// [operation] names the call in the message, so a host log says which surface
/// degraded.
Future<T> runGuarded<T>(
  String operation, {
  required Duration timeout,
  required Future<T> Function() body,
  SwayveCancellationToken? cancel,
}) async {
  cancel?.throwIfCancelled();
  try {
    final Future<T> work = body();
    final Future<T> raced = cancel == null
        ? work
        : Future.any(<Future<T>>[
            work,
            cancel.whenCancelled.then<T>(
              (_) => throw const SwayvePluginCancelledException(),
            ),
          ]);
    return await raced.timeout(
      timeout,
      onTimeout: () => throw SwayvePluginTimeoutException(
        'Lyrics: $operation exceeded its ${timeout.inMilliseconds}ms budget.',
        limit: timeout,
      ),
    );
  } on SwayvePluginException {
    rethrow;
  } on TimeoutException catch (error) {
    throw SwayvePluginTimeoutException(
      'Lyrics: $operation timed out.',
      limit: timeout,
      cause: error,
    );
  } catch (error) {
    // Principle 7: whatever this was, the host must still be able to classify
    // it. An unclassifiable failure is a transient one as far as the host is
    // concerned, and the original is carried along as the cause.
    throw SwayvePluginUnavailableException(
      'Lyrics: $operation failed unexpectedly.',
      cause: error,
    );
  }
}

/// Turns a non-2xx [response] from [source] into the right exception. Never
/// returns.
///
/// * `429` becomes `SwayvePluginRateLimitedException`, carrying `retryAfter`
///   parsed from the `Retry-After` header when the server sent a usable one.
///   Both services rate limit, and BetterLyrics publishes its budget in its
///   own response headers, so this is a status this plugin will meet in
///   ordinary use rather than a theoretical one.
/// * every other non-2xx status becomes `SwayvePluginUnavailableException`.
///
/// What is deliberately *not* here: `404` and `401`. Neither service uses
/// either to report a fault. LRCLIB's `404` is a `TrackNotFound` body and
/// means nobody has transcribed the recording; BetterLyrics' `401` is an
/// "API key required" body and means the recording is not in its anonymous
/// cache. Both of those are "no lyrics", which is the ordinary answer for most
/// tracks, and both are read by the source itself before it ever gets here.
Never throwForStatus(SwayveHttpResponse response, Uri url, String source) {
  if (response.statusCode == 429) {
    throw SwayvePluginRateLimitedException(
      '$source rate limited a request to ${url.host}.',
      retryAfter: parseRetryAfter(headerValue(response, 'retry-after')),
    );
  }
  throw SwayvePluginUnavailableException(
    '$source answered ${response.statusCode} for ${url.host}: '
    '${_snippetOf(response)}',
  );
}

/// A short, log-safe look at why a call failed.
///
/// Both services answer an error with a JSON object carrying a real message —
/// "Failed to find specified track", "Service running in cache-only mode" —
/// and a host log that only ever says "answered 503" has thrown that fact
/// away. Truncated hard: this exists to be read in a log line, not to
/// reproduce a lyric.
String _snippetOf(SwayveHttpResponse response) {
  final String body = response.bodyAsString.trim();
  if (body.isEmpty) return '(empty body)';
  return body.length > 300 ? '${body.substring(0, 300)}…' : body;
}

/// Reads [name] from [response] without assuming the host lower-cased it.
String? headerValue(SwayveHttpResponse response, String name) {
  final String wanted = name.toLowerCase();
  final String? direct = response.headers[wanted];
  if (direct != null) return direct;
  for (final MapEntry<String, String> entry in response.headers.entries) {
    if (entry.key.toLowerCase() == wanted) return entry.value;
  }
  return null;
}

/// Parses a `Retry-After` header value, or returns `null`.
///
/// Both forms RFC 9110 allows are accepted: delta-seconds, and an HTTP-date
/// which is turned into a delay from now. An unparseable value is `null`
/// rather than a guess — the host's own backoff is a better answer than a
/// fabricated one.
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null) return null;
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return null;

  final int? seconds = int.tryParse(trimmed);
  if (seconds != null) {
    return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
  }

  final DateTime? when = _parseHttpDate(trimmed);
  if (when == null) return null;
  final Duration delta = when.difference((now ?? DateTime.now()).toUtc());
  return delta.isNegative ? Duration.zero : delta;
}

const List<String> _months = <String>[
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

final RegExp _imfFixdate = RegExp(
  r'^[A-Za-z]{3},\s+(\d{2})\s+([A-Za-z]{3})\s+(\d{4})\s+'
  r'(\d{2}):(\d{2}):(\d{2})\s+GMT$',
);

/// Parses the IMF-fixdate form of an HTTP date, the only form a server is
/// allowed to send today.
///
/// Written out rather than delegated because `dart:io`'s `HttpDate` is off
/// limits: a plugin's `lib/` is pure Dart and host-mediated (contract §11).
DateTime? _parseHttpDate(String value) {
  final RegExpMatch? match = _imfFixdate.firstMatch(value);
  if (match == null) return null;
  final int month = _months.indexOf(match.group(2)!.toLowerCase()) + 1;
  if (month == 0) return null;
  return DateTime.utc(
    int.parse(match.group(3)!),
    month,
    int.parse(match.group(1)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6)!),
  );
}
