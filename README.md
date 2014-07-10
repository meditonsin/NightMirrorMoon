NightMirrorMoon
===============

Make mirrors of

 * Deviantart to imgur
 * Tumblr to imgur
 * GIFs from Deviantart and imgur to Gfycat

on Reddit.


How to use
----------

Copy or rename `nmm.conf.example` to `nmm.conf` and fill in the values.

Make a reddit account and put the credentials into the `reddit_account`
and `reddit_password` keys. The account might need some karma in
the subreddit it's supposed to work in and ideally a verified email
address, to get around reddit's rate limiting.  ([See here for more
info.](http://www.reddit.com/r/help/wiki/faq#wiki_why_am_i_being_told_.22you.27re_doing_that_too_much....22_i.27ve_been_here_for_years.21))

Make an imgur account and [register](http://api.imgur.com/#register) the
bot. Put the App-ID you get from there into `imgur_appid`.

Make a tumblr account and [register](http://www.tumblr.com/oauth/apps)
the bot. Put the API key into `$tumblr_api_key`.

Not strictly necessary, but probably for the best, is to change
the user agent string of the `REST::Client` instance that does
calls to reddit to something of your own.  [See here for more
info.](https://github.com/reddit/reddit/wiki/API) This can be set in the
`useragent` key.

There's also the option to only mirror content that is tagged as mature,
to allow people without DA accounts to see it. Set `mature_only` to
`1` for that.

When the bot encounters an error while creating a mirror or deleting an
unused one (because it encountered an error elsewhere), it will retry
at most `max_retries` times, with a five second delay between each try.


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

GIFs from tumblr are currently not mirrored to Gfycat.
