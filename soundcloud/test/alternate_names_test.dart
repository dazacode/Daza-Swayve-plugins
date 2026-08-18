import 'package:soundcloud/src/parsing/track_parser.dart';
import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';
import 'package:test/test.dart';

import 'support.dart';

/// SoundCloud has been publishing the label's own view of a track all along;
/// until now this plugin read one boolean out of it and threw the rest away.
/// These prove the names come through, and — just as importantly — that
/// nothing is invented when they are absent.
void main() {
  group('publisher_metadata becomes alternate names', () {
    late SwayveTrack track;

    setUp(() {
      final SwayveTrack? parsed =
          parseTrack(fixture('track_full.json')! as Map<String, Object?>);
      expect(parsed, isNotNull);
      track = parsed!;
    });

    test('the registered credit arrives as the original artist', () {
      // The handle the track is credited to and the name the release was
      // registered under are different strings, and on this fixture they are
      // different scripts. Somebody searching either should find the song.
      expect(track.artistsLabel, 'TestArtist');
      expect(track.alternateNames.originalArtist, 'テストアーティスト');
    });

    test('the album title arrives, since nothing else in the row states one',
        () {
      expect(track.album, isNull);
      expect(track.alternateNames.originalAlbum, 'Neon Highway');
    });

    test('a release title that disagrees with the album title is an alias', () {
      expect(
        track.alternateNames.aliases,
        contains('Neon Highway (Deluxe)'),
      );
    });

    test("the account's display name is an alias when it is a second string",
        () {
      expect(track.alternateNames.aliases, contains('Test Artist Full Name'));
    });

    test('a composer credit is not treated as another name for this artist',
        () {
      // `writer_composer` is in the fixture and is a different person. Filing
      // it as an alias would mean searching for the writer returned the
      // performer's whole catalogue.
      expect(track.alternateNames.allNames, isNot(contains('Somebody Else')));
    });

    test('the canonical title is untouched by any of it', () {
      expect(track.title, 'Midnight Drive');
      expect(track.alternateNames.originalTitle, isNull);
    });

    test('nothing is romanized or translated, because nothing said so', () {
      // SoundCloud publishes neither, and this plugin must not compute one:
      // a romanization it guessed would be indistinguishable downstream from
      // one the service stated, and the whole value of the source stamp is
      // that the two can be told apart.
      expect(track.alternateNames.romanizedTitle, isNull);
      expect(track.alternateNames.romanizedArtist, isNull);
      expect(track.alternateNames.translatedTitle, isNull);
      expect(track.alternateNames.translatedArtist, isNull);
    });
  });

  group('a track with nothing extra to say', () {
    test('carries no alternate names at all', () {
      final SwayveTrack? track = parseTrack(<String, Object?>{
        'id': 1,
        'title': 'Bare',
        'user': <String, Object?>{'id': 2, 'username': 'Somebody'},
      });
      expect(track!.alternateNames, SwayveAlternateNames.none);
      expect(track.alternateNames.isEmpty, isTrue);
    });

    test('does not repeat a display name identical to the handle', () {
      final SwayveTrack? track = parseTrack(<String, Object?>{
        'id': 1,
        'title': 'Bare',
        'user': <String, Object?>{
          'id': 2,
          'username': 'Somebody',
          'full_name': 'Somebody',
        },
        'publisher_metadata': <String, Object?>{'artist': 'Somebody'},
      });
      expect(track!.alternateNames, SwayveAlternateNames.none);
    });

    test('does not repeat a release title identical to the album title', () {
      final SwayveTrack? track = parseTrack(<String, Object?>{
        'id': 1,
        'title': 'Bare',
        'user': <String, Object?>{'id': 2, 'username': 'Somebody'},
        'publisher_metadata': <String, Object?>{
          'album_title': 'One Record',
          'release_title': 'One Record',
        },
      });
      expect(track!.alternateNames.originalAlbum, 'One Record');
      expect(track.alternateNames.aliases, isEmpty);
    });

    test('the permalink slug is never read as a romanization', () {
      // It is ASCII by construction, which makes it look like a free
      // romanization of a non-Latin title. It is a URL slug — hyphenated,
      // lowercased, truncated — and passing it off as a published name would
      // be this plugin guessing under a label that means it did not.
      final SwayveTrack? track = parseTrack(<String, Object?>{
        'id': 1,
        'title': 'おやすみがこわい',
        'permalink': 'oyasumi-ga-kowai',
        'permalink_url': 'https://soundcloud.com/x/oyasumi-ga-kowai',
        'user': <String, Object?>{'id': 2, 'username': 'Somebody'},
      });
      expect(track!.alternateNames.allNames, isEmpty);
    });
  });
}
