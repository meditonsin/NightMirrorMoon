NightMirrorMoon
===============

Make imgur mirrors for Deviantart submissions on reddit.

Limitations
-----------

Direct DA link (i.e. non fav.me and links with an anchor in the URL)
will be scraped for the highest resolution embedded image (img.fullview
or img.dev-content-full) to bypass the shortcoming of the oEmbed API.

The oEmbed API Deviantart uses doesn't always return the highest
available resolution of images, which is only a minor problem, since
imgur compresses anything over a certain size anyway.

It also doesn't return GIFs for some reason, only still images (PNG or
whatever), which means GIFs won't be mirrored correctly.
