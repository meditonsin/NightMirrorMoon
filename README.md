NightMirrorMoon
===============

Make imgur mirrors for Deviantart submissions on reddit.

Limitations
-----------

The oEmbed API Deviantart uses doesn't always return the highest
available resolution of images, which is only a minor problem, since
imgur compresses anything over a certain size anyway.

It also doesn't return GIFs for some reason, only still images (PNG or
whatever), which means GIFs won't be mirrored correctly.
