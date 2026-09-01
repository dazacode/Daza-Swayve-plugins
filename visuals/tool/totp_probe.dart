// Prints a live Spotify token-endpoint URL for the embedded TOTP version.
// Sends nothing itself and needs no credential: the point is to find out
// whether Spotify accepts the *code*, which it answers for anonymous callers.
import 'package:visuals/visuals.dart';

void main() {
  final now = DateTime.now();
  final code = spotifyTotpAt(now);
  final url = Uri.parse('https://open.spotify.com/api/token').replace(
    queryParameters: <String, String>{
      'reason': 'init',
      'productType': 'web-player',
      'totp': code,
      'totpServer': code,
      'totpVer': '$kSpotifyTotpVersion',
    },
  );
  print(url);
}
