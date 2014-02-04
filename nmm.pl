#!/usr/bin/perl -w
#
# Make imgur mirrors for Deviantart submissions on reddit
#
#
# Copyright (c) 2013 meditonsin
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

use strict;
use Proc::ProcessTable;
use URI::Escape;
use REST::Client;
use LWP::Simple;
use Mojo::DOM;
use JSON;

#
# Don't make mirrors of works of these artists
#
my @ignore_artists = (
   'FallenZephyr',
   'Kalyandra',
   'RabbitTales'
);

#
# Don't mirror posts by these submitters
#
my @ignore_submitters = (
   'stabbing_robot'
);

#
# If this is set to 1, the bot will only mirror images that are tagged as mature
# ( 'rating' attribute of oEmbed)
#
my $mature_only = 0;

my $maintainer = "meditonsin";
my $useragent = "NightMirrorMoon/0.1 by $maintainer";

my $imgur_appid = "secret";

my $reddit_account = "NightMirrorMoon";
my $reddit_password = "secret";
my $subreddit = "mylittlepony";



#
# Prevent multiple instances from running at the same time
#
my $count = 0;
my $table = Proc::ProcessTable->new;
for my $process ( @{$table->table} ) {
   if ( ! $process->{cmndline} ) {
      next;
   }
   if ( $process->{cmndline} =~ /$0/ ) {
      if ( $process->{cmndline} !~ /\/bin\/sh/ ) {
         $count++;
      }
      if ( $count > 1 ) {
         print "Already running!\n";
         exit;
      }
   }
}

my $reddit = REST::Client->new( { host => "http://www.reddit.com" } );
# https://github.com/reddit/reddit/wiki/API
$reddit->getUseragent->agent( $useragent );
# Need cookies or logins won't last
$reddit->getUseragent->cookie_jar({ file => "/tmp/cookies.txt" });

my $deviantart = REST::Client->new( { host => "http://backend.deviantart.com" } );
$deviantart->getUseragent->agent( $useragent );

my $imgur = REST::Client->new( { host => "https://api.imgur.com" } );
$imgur->getUseragent->agent( $useragent );
$imgur->addHeader( "Authorization", "Client-ID $imgur_appid" );

my $gfy = REST::Client->new( { host => "http://upload.gfycat.com" } );
$gfy->getUseragent->agent( $useragent );

my $tumblr = REST::Client->new( { host => "http://api.tumblr.com/v2" } );
$tumblr->getUseragent->agent( $useragent );

my $lastrunfile = "$0.lastrun";
my $logfile = "$0.log";
my $gfy_logfile = "$0_gfy.log";
my $errorlog = "$0.err";


#
# Get UTC time of last successful run
#
sub get_lastrun {
   if ( ! -e $lastrunfile ) {
      return 0;
   }
   open( LRUN, "<", $lastrunfile ) or die "Can't open $lastrunfile: $!";
   my $lastrun = <LRUN>;
   close( LRUN );
   
   return $lastrun;
}

#
# Set UTC time of last successful run
#
sub set_lastrun {
   my $time = shift;
   open( LRUN, ">", $lastrunfile ) or die "Can't open $lastrunfile: $!";
   print LRUN $time;
   close( LRUN );
}

#
# Log mirror info (including delete hash) to $logfile
#
sub log_mirror {
   my $mirror = shift;
   my $reddit_post = shift;
   my $datetime = `/bin/date +'%F %T'`;
   chomp( $datetime );

   # Log imgur mirror
   if ( $mirror->{data}->{id} ) {
      open( LOG, ">>", $logfile ) or die "Can't open $logfile: $!";
      binmode LOG, ":encoding(UTF-8)";
      print LOG "$datetime $mirror->{data}->{id} $mirror->{data}->{deletehash} $reddit_post->{data}->{permalink} $mirror->{data}->{author_name}\n";
      close( LOG );
   }

   # Log gfy mirror
   if ( $mirror->{gfy} ) {
      open( GFYLOG, ">>", $gfy_logfile ) or die "Can't open $gfy_logfile: $!";
      binmode GFYLOG, ":encoding(UTF-8)";
      print GFYLOG "$datetime $mirror->{gfy}->{gfyname} $reddit_post->{data}->{permalink} $mirror->{data}->{author_name}\n";
      close( GFYLOG );
   }
}

#
# Log an error
#
sub log_error {
   my $message = shift;
   my $datetime = `/bin/date +'%F %T'`;
   chomp( $datetime );
   chomp( $message );

   open( LOG, ">>", $errorlog ) or die "Can't open $errorlog: $!";
   binmode LOG, ":encoding(UTF-8)";
   print LOG "$datetime $message\n";
   close( LOG );
}

#
# Go through $logfile to see if we already posted on a link.
# When reddit is under load, we sometimes get unreliable data,
# which ends in double posts.
#
sub post_in_log {
   my $check_link = shift;

   if ( ! -f $logfile ) {
      return 0;
   }

   open( LOG, "<", $logfile ) or die "Can't open $logfile: $!";
   while ( my $line = <LOG> ) {
      chomp( $line );
      my ( $date, $time, $imgur_id, $imgur_delhash, $reddit_link, $artist ) = split( / /, $line );
      if ( $check_link eq $reddit_link ) {
         close( LOG );
         return 1;
      }
   }
   close( LOG );

   open( GFYLOG, "<", $gfy_logfile ) or die "Can't open $gfy_logfile: $!";
   while ( my $line = <GFYLOG> ) {
      chomp( $line );
      my ( $date, $time, $gfyname, $reddit_link, $artist ) = split( / /, $line );
      if ( $check_link eq $reddit_link ) {
         close( GFYLOG );
         return 1;
      }
   }
   close( GFYLOG );

   return 0;
}

#
# Get list of posts from a subreddit or list of comments from a post
#
sub get_reddit {
   my $r = shift;
   my $url = shift;

   $r->request( "GET", $url );

   if ( $r->responseCode == 200 ) {
      return from_json( $r->responseContent );
   }
   log_error( "get_reddit(): Couldn't fetch $url; got HTTP " . $r->responseCode );
   return undef;
}

#
# Translate Deviantart URL into direct link to the image via DA's oEmbed API
# Doesn't give the highest available res and doesn't do gifs
# (returns a png or whatever)
#
sub get_da {
   my $r = shift;
   my $dalink = shift;
   my $url = uri_escape( $dalink );

   $r->request( "GET", "/oembed?format=json&url=$url" );

   if ( $r->responseCode == 200 ) {
      my $response = from_json( $r->responseContent );

      if ( $response->{type} ne "link" and $response->{type} ne "photo" ) {
         return undef;
      }

      if ( $mature_only and ( ! $response->{rating} or $response->{rating} ne 'adult' ) ) {
         return undef;
      }

      foreach my $artist ( @ignore_artists ) {
         if ( $response->{author_name} =~ /^\Q$artist\E$/i ) {
            return undef;
         }
      }

      if ( $response->{type} eq "link" ) {
         $response->{url} = $response->{fullsize_url};
      }

      # To try to make GIFs work
      my $scraped_image = get_da_scrape( $dalink );
      if ( $scraped_image ) {
         # Ignore flash previews
         if ( $scraped_image eq "FLASH" ) {
            return undef;
         }
         $response->{url} = $scraped_image;
      }

      return $response;
   }
   log_error( "get_da(): Couldn't fetch $url; got HTTP " . $r->responseCode );
   return undef;
}

#
# Scrape HTML of Deviantart link for "fullview" image.
# It's higher res than what the API returns and works with GIFs. Only
# works with proper links, though. fav.me and links with anchors in the
# URL that get resolved via JS won't do.
#
sub get_da_scrape {
   my $dalink = shift;

   my $html = get( $dalink );
   if ( ! $html ) {
      log_error( "get_da_scrape(): Failed to get $dalink" );
      return undef;
   }
   my $dom = Mojo::DOM->new( $html );
   if ( ! $dom ) {
      log_error( "get_da_scrape(): Failed to parse $dalink" );
      return undef;
   }

   # Check if this is a flash animation
   # We don't need a mirror of the preview
   my $is_flash = $dom->at( 'iframe[class~=flashtime]' );
   if ( $is_flash ) {
      log_error( "get_da_scrape(): Won't fetch $dalink; FLASH" );
      return "FLASH";
   }

   # Assigns different class names to the img tag every other call
   # for some reason
   my $fullview = $dom->at( 'img[class~=fullview]' );
   if ( ! $fullview ) {
      $fullview = $dom->at( 'img[class~=dev-content-full]' );
      if ( ! $fullview ) {
         log_error( "get_da_scrape(): Couldn't find fullview of $dalink" );
         return undef;
      }
   }

   return $fullview->attrs( 'src' );
}

#
# Get info on an imgur image
#
sub get_imgur {
   my $r = shift;
   my $url = shift;

   if ( $url !~ /imgur.com\/([^.\/]+)(\.[^\.\/]+|:?)$/i ) {
      return undef;
   }

   $r->request( "GET", "/3/image/$1", undef );

   if ( $r->responseCode == 200 ) {
      return from_json( $r->responseContent );
   }

   return undef;
}

#
# Mirror a gif to gfycat
#
sub make_gfy_mirror {
   my $r = shift;
   my $gif_url = shift;
   my $url = uri_escape( $gif_url );

   if ( $gif_url !~ /\.gif$/i ) {
      return undef;
   }

   $r->request( "GET", "/transcode?fetchUrl=$url" );

   if ( $r->responseCode == 200 ) {
      return from_json( $r->responseContent );
   }
   log_error( "make_gfy_mirror(): Failed to mirror $gif_url to gfy; Got HTTP " . $r->responseCode );
   return undef;
}

#
# Make imgur mirror
#
sub make_imgur_mirror {
   my $r = shift;
   my $url = uri_escape( shift );
   my $title = uri_escape( shift );
   my $description = uri_escape( shift );
   my $query_string = "image=$url&title=$title&description=$description";

   $r->request( "POST", "/3/image.json?$query_string", undef );

   if ( $r->responseCode == 400 ) {
      my $response = from_json( $r->responseContent );
      if ( $response->{data}->{error} =~ /^Image is larger than / or
           $response->{data}->{error} =~ /^Animated GIF is larger than / ) {
         log_error( "make_imgur_mirror(): Didn't mirror $url; TOO_LARGE" );
         return $response;
      }
   }

   if ( $r->responseCode == 200 ) {
      return from_json( $r->responseContent );
   }

   log_error( "make_imgur_mirror(): Failed to mirror $url; Got HTTP " . $r->responseCode );
   return undef;
}

#
# Mirror deviantart to imgur
#
sub mirror_da {
   my $r = shift;
   my $da = shift;
   my $gfy = shift;
   my $da_link = shift;
   my $da_image = get_da( $da, $da_link );

   if ( ! $da_image ) {
      return undef;
   }

   my $gfy_mirror;
   if ( $da_image->{url} =~ /\.gif$/i ) {
      $gfy_mirror = make_gfy_mirror( $gfy, $da_image->{url} );
   }

   my $mirror = make_imgur_mirror(
      $r,
      $da_image->{url},
      "$da_image->{title} by $da_image->{author_name}",
      "This image was reuploaded by a bot on reddit.com/r/$subreddit from Deviantart. The original can be found here: $da_link"
   );

   if ( $mirror or $gfy_mirror ) {
      $mirror->{gfy} = $gfy_mirror;
      $mirror->{data}->{author_name} = $da_image->{author_name};
      return $mirror;
   }

   return undef;
}

#
# Mirror gif from imgur to gfycat
#
sub mirror_imgur {
   my $r = shift;
   my $gfy = shift;
   my $imgur_link = shift;
   my $imgur_image = get_imgur( $r, $imgur_link );

   if ( ! $imgur_image ) {
      return undef;
   }

   # Not a gif
   if ( ! $imgur_image->{data}->{animated} ) {
      return undef;
   }

   if ( $mature_only and ( ! $imgur_image->{data}->{nsfw} ) ) {
      return undef;
   }

   my $gfy_mirror = make_gfy_mirror( $gfy, $imgur_image->{data}->{link} );
   if ( $gfy_mirror ) {
      my $mirror = {
         gfy  => $gfy_mirror,
         data => {
            author_name => '-'
         }
      };
      return $mirror
   }

   return undef;
}

#
# Delete imgur mirror
#
sub delete_imgur_mirror {
   my $r = shift;
   my $dhash = shift;

   $r->request( "DELETE", "/3/image/$dhash" );

   if ( $r->responseCode == 200 ) {
      return 1;
   }
   log_error( "delete_imgur_mirror(): Failed to remove mirror $dhash; Got HTTP " . $r->responseCode );
}

#
# Submit mirror to reddit post
#
sub make_reddit_comment {
   my $r = shift;
   my $post = shift;
   my @links = @_;

   my $response = undef;

   #
   # Login to reddit
   # (only do it once)
   #
   if ( ! $r->{_headers}{'X-Modhash'} ) {
      my $login_query = "user=$reddit_account&passwd=$reddit_password&rem=false&api_type=json";
      $r->request( "POST", "/api/login?$login_query" );
      if ( $r->responseCode != 200 ) {
         log_error( "make_reddit_comment(): Failed to log in; Got HTTP " . $r->responseCode );
         return undef;
      }
      $response = from_json( $r->responseContent );
      if ( ! $response->{json}->{data} ) {
         log_error( "make_reddit_comment(): Failed to parse login response" );
         return undef;
      }

      # Modhash is required for write operations
      # We also use it as an indication that we are logged in
      $r->addHeader( "X-Modhash", $response->{json}->{data}->{modhash} );
   }

   #
   # Post comment with mirror link
   #
   my $links = join( "  \n", @links );
   my $comment_text = uri_escape( "[](/nmm)$links  \n  \n[](/sp)  \n  \n---  \n  \n^(This is a bot | )[^Info](/r/mylittlepony/comments/1lwzub/deviantart_imgur_mirror_bot_nightmirrormoon/)^( | )[^(Report problems)](/message/compose/?to=$maintainer&subject=$reddit_account)^( | )[^(Source code)](https://github.com/meditonsin/NightMirrorMoon)" );
   my $comment_query = "text=$comment_text&thing_id=$post&api_type=json";
   $r->request( "POST", "/api/comment?$comment_query" );
   if ( $r->responseCode != 200 ) {
      log_error( "make_reddit_comment(): Failed post comment; Got HTTP " . $r->responseCode );
      return undef;
   }
   $response = from_json( $r->responseContent );
   if ( ! $response->{json}->{data} ) {
      log_error( "make_reddit_comment(): Failed post comment; Got Reddit response: " . $response->{json}->{errors}->[0]->[0] );
      return undef;
   }

   return $response;
}

my $lastrun = get_lastrun();

# Don't record time of last run if we had errors,
# so we can try again on the posts that didn't work out
my $errors = 0;

my $posts = get_reddit( $reddit, "/r/$subreddit/new/.json" );
my $now = time();
if ( ! $posts ) {
   exit;
}
foreach my $post ( @{$posts->{data}->{children}} ) {
   # Skip non-DA posts
   # Direct links are deviantart.net, which are already taken care of by Trixie
   if ( $post->{data}->{domain} !~ /(deviantart\.com|fav\.me|imgur\.com)$/ ) {
      next;
   }

   #
   # Skip posts by certain reddit users
   #
   foreach my $submitter ( @ignore_submitters ) {
      if ( $post->{data}->{author} =~ /^\Q$submitter\E$/i ) {
         log_error( "main(): Skipped reddit user $post->{data}->{author}\@$post->{data}->{permalink}" );
         return next;
      }
   }

   # Skip posts since last successful run
   if ( $post->{data}->{created_utc} < $lastrun ) {
      next;
   }

   # Skip posts $reddit_account already commented on
   # (only check top level comments)
   my $did_it = 0;
   my $comments = get_reddit( $reddit, $post->{data}->{permalink}.".json" );
   if ( ! $comments ) {
      $errors = 1;
      next;
   }
   foreach my $comment ( @{$comments->[1]->{data}->{children}} ) {
      if ( $comment->{data}->{author} =~ /^\Q$reddit_account\E$/i ) {
         $did_it = 1;
         last;
      }
   }
   if ( $did_it ) {
      next;
   }
   if ( post_in_log( $post->{data}->{permalink} ) ) {
      next;
   }

   # Make a mirror
   my $mirror;
   if ( $post->{data}->{domain} =~ /imgur.com$/i ) {
      $mirror = mirror_imgur( $imgur, $gfy, $post->{data}->{url} );
      if ( ! $mirror ) {
         next;
      }
   } else {
      $mirror = mirror_da( $imgur, $deviantart, $gfy, $post->{data}->{url} );
   }

   if ( ! $mirror ) { 
      $errors = 1;
      next;
   }
   if ( $mirror->{data} and $mirror->{data}->{error} and (
           $mirror->{data}->{error} =~ /^Image is larger than / or
           $mirror->{data}->{error} =~ /^Animated GIF is larger than /
        )
   ) {
      if ( ! $mirror->{gfy} ) {
         next;
      }
   }

   # Make list of mirror links
   my @links;
   if ( $mirror->{data} and $mirror->{data}->{id} ) {
      push @links, "[Imgur mirror](http://imgur.com/" . $mirror->{data}->{id} . ")";
   }
   if ( $mirror->{gfy} and $mirror->{gfy}->{gfyname} ) {
      push @links, "[Gfycat mirror](http://gfycat.com/" . $mirror->{gfy}->{gfyname} . ")";
   }

   # Make comment in submission post
   if ( ! make_reddit_comment( $reddit, $post->{data}->{name}, @links ) ) {
      # Don't leave the now useless mirror up
      delete_imgur_mirror( $imgur, $mirror->{data}->{deletehash} );
      $errors = 1;
      next;
   }

   log_mirror( $mirror, $post );
}

if ( ! $errors ) {
   set_lastrun( $now );
}
