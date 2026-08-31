/// Everything this plugin knows about the outside world, as constants.
///
/// Each value here has a counterpart in `plugin.json`, and
/// `test/manifest_agreement_test.dart` reads the manifest and asserts they
/// still agree. That test is the reason these are constants rather than
/// strings scattered through the source files: a plugin whose code reaches a
/// host its manifest does not declare has escaped the permission model, and
/// the cheapest way to notice is to keep both halves in one place and compare
/// them.
library;

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// The plugin id, identical to `plugin.json`'s `id`.
const String kLyricsPluginId = 'app.swayve.plugins.lyrics';

/// The human-readable name, identical to `plugin.json`'s `name`.
const String kLyricsPluginName = 'Lyrics';

/// The plugin version, identical to `plugin.json`'s `version`.
const Version kLyricsPluginVersion = Version(0, 1, 0);

/// The hostnames this plugin is permitted to reach, identical to
/// `plugin.json`'s `network.hosts`.
///
/// The host enforces this list; the plugin restates it so that
/// [isAllowedHost] can refuse to *build* a URL that would be rejected, and so
/// that `test/network_allowlist_test.dart` can prove no code path ever tries.
///
/// Two hosts, and both of them are free, keyless and open-licensed — which is
/// the whole reason this plugin can exist without a sign-in flow. Nothing
/// else is on this list, and in particular no lyric site that would have to
/// be scraped: reading a page that was never offered as an API is a different
/// thing from calling one that was, and it is not what this plugin does.
const List<String> kLyricsAllowedHosts = <String>[
  'lrclib.net',
  'lyrics-api.boidu.dev',
];

/// Whether [host] is covered by [kLyricsAllowedHosts].
///
/// Matching mirrors the manifest's own rule: an entry is either an exact
/// hostname or a single `*.` wildcard covering one or more leading labels.
/// This plugin declares no wildcards, but the rule is implemented in full so
/// that adding one later cannot quietly mean something different here than it
/// means to the host.
bool isAllowedHost(String host) {
  final String candidate = host.toLowerCase();
  for (final String pattern in kLyricsAllowedHosts) {
    if (pattern.startsWith('*.')) {
      final String suffix = pattern.substring(1).toLowerCase();
      if (candidate.endsWith(suffix) && candidate.length > suffix.length) {
        return true;
      }
    } else if (candidate == pattern.toLowerCase()) {
      return true;
    }
  }
  return false;
}

/// LRCLIB's exact-match endpoint.
///
/// It takes the whole recording — title, credit, release and running time —
/// and answers with the one record that matches all four, or `404`. That is
/// the request this plugin wants to make: the answer needs no adjudicating,
/// because the service has already applied its own duration tolerance and
/// decided.
final Uri kLrcLibGetEndpoint = Uri.parse('https://lrclib.net/api/get');

/// LRCLIB's search endpoint, used only when [kLrcLibGetEndpoint] says `404`.
///
/// It answers with up to twenty loosely-matched candidates and adjudicates
/// nothing, so everything it returns has to be checked here before it is
/// believed. See `sources/lrclib_source.dart`.
final Uri kLrcLibSearchEndpoint = Uri.parse('https://lrclib.net/api/search');

/// BetterLyrics' lyric endpoint.
///
/// The parameter names were read off the service's own index document rather
/// than guessed: `s`/`song`/`songName` and `a`/`artist`/`artistName` are
/// required, `al`/`album`/`albumName` and `d`/`duration` optional and
/// described there as improving the match. This plugin sends the short forms
/// and all four when it has them.
final Uri kBetterLyricsEndpoint =
    Uri.parse('https://lyrics-api.boidu.dev/getLyrics');

/// The attribution stamped on anything LRCLIB supplied.
///
/// LRCLIB publishes its corpus as CC0, so nothing here is legally required to
/// credit it. It is credited anyway: a listener looking at a lyric is owed
/// the name of whoever assembled it, and a lyric that arrived from a
/// crowd-maintained database is a different kind of claim from one licensed
/// off a label's own metadata.
const String kLrcLibSource = 'LRCLIB';

/// The attribution stamped on anything BetterLyrics supplied.
const String kBetterLyricsSource = 'BetterLyrics';

/// How far a candidate's running time may sit from the track's before it is
/// refused.
///
/// Two seconds, which is LRCLIB's own tolerance and is tight on purpose. A
/// database of user-submitted lyrics has many records under the same title
/// and credit — a radio edit, a live take, an extended mix, a compilation
/// re-master — and their words and their timings are genuinely different. The
/// failure this guards against is not "no lyrics"; it is a synced lyric that
/// drifts further out of time with every chorus, which reads as a bug in the
/// player rather than as a bad match.
const Duration kDurationTolerance = Duration(seconds: 2);

/// The `User-Agent` every request from this plugin carries.
///
/// LRCLIB's documentation asks clients to identify themselves and to include
/// a link back to the project. There is no API key and no account behind
/// either of these services, so this header is the entire contract: it is how
/// an operator seeing unusual traffic finds out whose it is and how to say
/// so. Sending a browser's user-agent string instead would be a small lie
/// told to a service that is giving us something for nothing.
const String kUserAgent =
    'Swayve-Lyrics/0.1.0 (https://github.com/dazacode/Daza-Swayve-plugins)';

/// The deadlines this plugin works to.
///
/// [manifest] mirrors `plugin.json`'s `timeouts` block. Tests construct their
/// own with millisecond budgets so that proving a deadline fires does not cost
/// twenty seconds of wall clock.
final class LyricsTimeouts {
  /// Creates a timeout budget.
  const LyricsTimeouts({required this.request, required this.operation});

  /// The budgets declared in `plugin.json`.
  static const LyricsTimeouts manifest = LyricsTimeouts(
    request: Duration(milliseconds: 10000),
    operation: Duration(milliseconds: 20000),
  );

  /// The budget for one outbound HTTP request.
  final Duration request;

  /// The budget for one complete provider call, covering every source it
  /// asks.
  final Duration operation;
}
