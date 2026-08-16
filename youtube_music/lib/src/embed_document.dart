/// The page the host renders in place of navigating to YouTube's embed URL.
///
/// ## Why a page of our own rather than YouTube's
///
/// Loading `youtube.com/embed/<id>` directly puts the service's own player on
/// screen, with its own controls, its own chrome and no way for the host to
/// touch any of it. `enablejsapi=1` is on that URL and always has been, but the
/// API it enables is driven by `postMessage` **from the containing frame** — and
/// when the embed page *is* the top document there is no containing frame to
/// send from. The host was left rendering a sealed rectangle.
///
/// This document is that containing frame. It is a dozen lines of HTML that
/// load YouTube's IFrame Player API, put the player in an iframe of its own, and
/// re-expose it under the fixed names in [SwayveEmbedBridge]. The host calls
/// `__swayve.play()` without ever learning that `player.playVideo()` is what
/// happens next, which is the whole point: every piece of YouTube-specific
/// knowledge in this feature is in this file, and the host has none of it.
///
/// ## Why the player's own chrome is turned off
///
/// `controls=0` and the flags beside it are not decoration. Once the host draws
/// its own transport there are two sets of controls on one video, they disagree
/// the moment either is touched, and the one underneath is the one nobody
/// asked for. Turning them off is what makes the host's transport the truth
/// rather than a second opinion.
library;

import 'dart:convert';

import 'package:swayve_plugin_sdk/swayve_plugin_sdk.dart';

/// Builds the adapter page for [videoId].
///
/// [origin] is the page's own address, which the host loads it under and which
/// YouTube requires to match the `origin` parameter — the API refuses to talk
/// to a frame whose stated origin disagrees with where it is running.
String youTubeEmbedDocument({
  required String videoId,
  required String origin,
}) {
  // Encoded rather than interpolated. A video id is eleven characters of
  // `[A-Za-z0-9_-]` and could not break out of a string literal if it tried,
  // but this file writes JavaScript by concatenation and the moment one value
  // is trusted the next one is too.
  final String id = jsonEncode(videoId);
  final String host = jsonEncode(origin);
  final String channel = SwayveEmbedBridge.channelName;
  final String object = SwayveEmbedBridge.objectName;

  return '''
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<style>
  /* The page is the video and nothing else. Any margin here reads on screen as
     a hairline of the wrong colour down the edge of the picture. */
  html, body { margin: 0; padding: 0; height: 100%; background: #000; overflow: hidden; }
  #player { width: 100%; height: 100%; border: 0; display: block; }
</style>
<div id="player"></div>
<script>
(function () {
  var player = null;
  var ready = false;
  var ticker = null;

  function post(type, extra) {
    var message = { type: type, playing: false, position: 0 };
    if (player && ready) {
      try {
        message.position = player.getCurrentTime() || 0;
        var length = player.getDuration();
        // A live stream reports 0, which is not a duration and would draw a
        // scrubber that is permanently at the end.
        if (length && isFinite(length) && length > 0) message.duration = length;
        message.playing = player.getPlayerState() === 1;
      } catch (error) {
        // The player object exists but is between states. Reporting what we
        // have beats dropping the event.
      }
    }
    if (extra) for (var key in extra) message[key] = extra[key];
    try {
      window.$channel.postMessage(JSON.stringify(message));
    } catch (error) {
      // No channel: the page is being viewed outside the host. Nothing to do,
      // and certainly not something to throw over.
    }
  }

  // The player's own reason, in a sentence somebody can act on.
  //
  // Worth the lines. "This video cannot be played here" was what every failure
  // used to say, and it is the least useful of the true things available: the
  // player states a numbered reason, and the numbers mean genuinely different
  // situations — one is a bad id, one is a video that has been taken down, and
  // two of them mean the owner allows this video on YouTube and nowhere else.
  // Told which, the host can offer the way out that actually works instead of
  // leaving somebody tapping a picture that was never going to play.
  //
  // 101 and 150 are the same refusal reported two ways, which is a quirk of
  // the API rather than a distinction worth carrying.
  function describeError(code) {
    switch (code) {
      case 2: return 'YouTube did not recognise this video.';
      case 5: return 'This video will not play in an embedded player.';
      case 100: return 'This video is no longer on YouTube.';
      case 101:
      case 150: return 'The owner of this video only allows it to be watched on YouTube.';
      default: return 'This video cannot be played here.';
    }
  }

  // Position is polled rather than pushed because the API has no event for it.
  // Four times a second is finer than a scrubber can show and costs nothing;
  // it runs only while playing, so a paused video is silent.
  function startTicking() {
    if (ticker) return;
    ticker = setInterval(function () { post('state'); }, 250);
  }
  function stopTicking() {
    if (!ticker) return;
    clearInterval(ticker);
    ticker = null;
  }

  window.$object = {
    play: function () { if (player) player.playVideo(); },
    pause: function () { if (player) player.pauseVideo(); },
    // Seconds, per the bridge. `true` lets the player seek ahead of what it has
    // buffered, which is what somebody dragging a scrubber means.
    seek: function (seconds) { if (player) player.seekTo(Number(seconds), true); },
    setMuted: function (muted) {
      if (!player) return;
      if (muted) player.mute(); else player.unMute();
    }
  };

  window.onYouTubeIframeAPIReady = function () {
    player = new YT.Player('player', {
      videoId: $id,
      playerVars: {
        // The host draws the transport now. Two sets of controls on one video
        // disagree the moment either is touched.
        controls: 0,
        // In place, not full-screen-on-play. The host decides how big the
        // picture is.
        playsinline: 1,
        // No end-screen grid of unrelated channels over the last five seconds
        // of the song, no annotations, no keyboard handling competing with the
        // host's, and no full-screen button belonging to a player the user
        // cannot see.
        rel: 0,
        iv_load_policy: 3,
        disablekb: 1,
        fs: 0,
        modestbranding: 1,
        origin: $host
      },
      events: {
        onReady: function () {
          ready = true;
          post('ready');
        },
        onStateChange: function (event) {
          // 1 playing, 0 ended. Everything else — buffering, paused, cued —
          // is a state change worth reporting but not worth a name here: the
          // host reads `playing`, and inventing a vocabulary for YouTube's
          // integers would be exporting YouTube's model through a bridge whose
          // entire purpose is not to.
          if (event.data === 1) startTicking(); else stopTicking();
          if (event.data === 0) { post('ended'); return; }
          post('state');
        },
        onError: function (event) {
          stopTicking();
          post('error', { message: describeError(event && event.data) });
        }
      }
    });
  };
})();
</script>
<script src="https://www.youtube.com/iframe_api"></script>
''';
}
