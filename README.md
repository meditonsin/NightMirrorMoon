NightMirrorMoon
===============

Make imgur mirrors for Deviantart submissions on reddit.


How to use
----------

Put the subreddit the bot will work in the `$subreddit` variable.

Make a reddit account and put the credentials into the `$reddit_account`
and `$reddit_password` variables. The account might need some karma in
the subreddit it's supposed to work in and ideally a verified email
address, to get around reddit's rate limiting.  ([See here for more
info.](http://www.reddit.com/r/help/wiki/faq#wiki_why_am_i_being_told_.22you.27re_doing_that_too_much....22_i.27ve_been_here_for_years.21))

Make an imgur account and [register](http://api.imgur.com/#register) the
bot. Put the App-ID you get from there into the `$imgur_appid` variable.

Not strictly necessary, but probably for the best, is to change
the user agent string of the `REST::Client` instance that does
calls to reddit to something of your own.  [See here for more
info.](https://github.com/reddit/reddit/wiki/API)


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
