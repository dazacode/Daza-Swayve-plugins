/// The single place a failure becomes a `SwayvePluginException`.
///
/// Spec §19: a provider method must complete, honour cancellation, or throw
/// one of the SDK's exceptions — never anything else. Every public provider
/// method in this plugin is therefore wrapped in [runGuarded], and every
/// non-2xx response goes through [throwForStatus]. Nothing else in the plugin
/// throws on purpose.
library;

import 'dart:async';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// Runs [body] as one provider operation.
///
/// It enforces the three things the contract asks of every provider call:
///
/// * **cancellation** — checked before any work starts, and raced against the
///   work afterwards, so a host that has lost interest is not made to wait for
///   an in-flight request;
/// * **the deadline** — [timeout] is the manifest's `timeouts.operationMs`,
///   covering the whole operation including every request it makes
///   internally (the client_id scrape, a retry after a 401, playlist
///   hydration's batched follow-ups), and a breach surfaces as
///   `SwayvePluginTimeoutException`;
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
        'SoundCloud: $operation exceeded its '
        '${timeout.inMilliseconds}ms budget.',
        limit: timeout,
      ),
    );
  } on SwayvePluginException {
    rethrow;
  } on TimeoutException catch (error) {
    throw SwayvePluginTimeoutException(
      'SoundCloud: $operation timed out.',
      limit: timeout,
      cause: error,
    );
  } catch (error) {
    // Principle 7: whatever this was, the host must still be able to classify
    // it. An unclassifiable failure is a transient one as far as the host is
    // concerned, and the original is carried along as the cause.
    throw SwayvePluginUnavailableException(
      'SoundCloud: $operation failed unexpectedly.',
      cause: error,
    );
  }
}

/// Turns a non-2xx [response] into the right exception. Never returns.
///
/// * `429` becomes `SwayvePluginRateLimitedException`, carrying `retryAfter`
///   parsed from the `Retry-After` header when the server sent a usable one.
/// * every other non-2xx status becomes `SwayvePluginUnavailableException`.
///
/// Note what is deliberately *not* here: `401` and `403` do not become
/// `SwayvePluginAuthRequiredException`. That exception tells the host to send
/// the user through this plugin's sign-in flow, and this plugin declares no
/// `authentication` capability and has no such flow — it talks to SoundCloud's
/// public API anonymously. A `401` here almost always means the scraped
/// `client_id` has gone stale, which `SoundCloudClient` already retries once
/// internally before this is ever reached; one that survives that retry is a
/// service condition, not a lapsed session, and reporting auth-required would
/// leave the host offering a button that leads nowhere.
Never throwForStatus(SwayveHttpResponse response, Uri url) {
  if (response.statusCode == 429) {
    throw SwayvePluginRateLimitedException(
      'SoundCloud rate limited a request to ${url.host}.',
      retryAfter: parseRetryAfter(headerValue(response, 'retry-after')),
    );
  }
  throw SwayvePluginUnavailableException(
    'SoundCloud answered ${response.statusCode} for ${url.host}.',
  );
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
