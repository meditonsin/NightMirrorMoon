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
$reddit->getUseragent->agent( "NightMirrorMoon/0.1 by meditonsin" );
# Need cookies or logins won't last
$reddit->getUseragent->cookie_jar({ file => "/tmp/cookies.txt" });

my $deviantart = REST::Client->new( { host => "http://backend.deviantart.com/oembed?format=json&url=" } );
my $imgur = REST::Client->new( { host => "https://api.imgur.com" } );

#
# Don't make mirrors of works of these artists
#
my @ignore_artists = (
   'FallenZephyr',
   'Kalyandra'
);

my $imgur_appid = "secret";
$imgur->addHeader( "Authorization", "Client-ID $imgur_appid" );

my $maintainer = "meditonsin";

my $reddit_account = "NightMirrorMoon";
my $reddit_password = "secret";
my $subreddit = "mylittlepony";

my $lastrunfile = "$0.lastrun";
my $logfile = "$0.log";

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

   open( LOG, ">>", $logfile ) or die "Can't open $logfile: $!";
   print LOG "$datetime $mirror->{data}->{id} $mirror->{data}->{deletehash} $reddit_post->{data}->{permalink} $mirror->{data}->{author_name}\n";
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
      my ( $date, $time, $imgur_id, $imgur_delhash, $reddit_link ) = split( / /, $line );
      if ( $check_link eq $reddit_link ) {
         close( LOG );
         return 1;
      }
   }
   close( LOG );
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
      my $response = from_json( $r->responseContent );
      return $response;
   }
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

   $r->request( "GET", $url );

   if ( $r->responseCode == 200 ) {
      my $response = from_json( $r->responseContent );

      if ( $response->{type} ne "link" and $response->{type} ne "photo" ) {
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
         $response->{url} = $scraped_image;
      }

      return $response;
   }
   return undef;
}

#
# Scrap HTML of Deviantart link for "fullview" image.
# It's higher res than what the API returns and works with GIFs. Only
# works with proper links, though. fav.me and links with anchors in the
# URL that get resolved via JS won't do.
#
sub get_da_scrape {
   my $dalink = shift;

   my $html = get( $dalink );
   if ( ! $html ) {
      return undef;
   }
   my $dom = Mojo::DOM->new( $html );
   if ( ! $dom ) {
      return undef;
   }

   # Assigns different class names to the img tag every other call
   # for some reason
   my $fullview = $dom->at('img[class~=fullview]');
   if ( ! $fullview ) {
      $fullview = $dom->at('img[class~=dev-content-full]');
      if ( ! $fullview ) {
         return undef;
      }
   }

   return $fullview->attrs('src');
}

#
# Make imgur mirror
#
sub make_mirror {
   my $r = shift;
   my $da = shift;
   my $da_link = shift;
   my $da_image = get_da( $da, $da_link );

   if ( ! $da_image ) {
      return undef;
   }

   my $da_image_esc = uri_escape( $da_image->{url} );
   my $da_link_esc = uri_escape( "This image was reuploaded by a bot on reddit.com/r/$subreddit from Deviantart. The original can be found here: $da_link" );
   my $da_title_esc = uri_escape( "$da_image->{title} by $da_image->{author_name}" );
   my $query_string = "image=$da_image_esc&description=$da_link_esc&title=$da_title_esc";

   $r->request( "POST", "/3/image.json?$query_string", undef );

   my $response = from_json( $r->responseContent );
   if ( $r->responseCode == 200 ) {
      $response->{data}->{author_name} = $da_image->{author_name};
      return $response;
   }
   if ( $r->responseCode == 400 and $response->{data}->{error} =~ /^Image is larger than / ) {
      return "TOO_LARGE";
   }
   return undef;
}

#
# Delete imgur mirror
#
sub delete_mirror {
   my $r = shift;
   my $dhash = shift;

   $r->request( "DELETE", "/3/image/$dhash" );

   if ( $r->responseCode == 200 ) {
      return 1;
   }
   #die "Couldn't delete mirror $dhash (".$response->{data}->{error}.")";
}

#
# Submit mirror to reddit post
#
sub make_reddit_comment {
   my $r = shift;
   my $post = shift;
   my $mirror = shift;

   my $response = undef;

   #
   # Login to reddit
   # (only do it once)
   #
   if ( ! $r->{_headers}{'X-Modhash'} ) {
      my $login_query = "user=$reddit_account&passwd=$reddit_password&rem=false&api_type=json";
      $r->request( "POST", "/api/login?$login_query" );
      if ( $r->responseCode != 200 ) {
         return undef;
      }
      $response = from_json( $r->responseContent );
      if ( ! $response->{json}->{data} ) {
         return undef;
      }

      # Modhash is required for write operations
      # We also use it as an indication that we are logged in
      $r->addHeader( "X-Modhash", $response->{json}->{data}->{modhash} );
   }

   #
   # Post comment with mirror link
   #
   my $comment_text = uri_escape( "[](/nmm)[Imgur mirror](http://imgur.com/$mirror)  \n  \n[](/sp)  \n  \n---  \n  \n^(This is a bot | )[^Info](/r/mylittlepony/comments/1lwzub/deviantart_imgur_mirror_bot_nightmirrormoon/)^( | )[^(Report problems)](/message/compose/?to=$maintainer&subject=$reddit_account)^( | )[^(Source code)](https://github.com/meditonsin/NightMirrorMoon)" );
   my $comment_query = "text=$comment_text&thing_id=$post&api_type=json";
   $r->request( "POST", "/api/comment?$comment_query" );
   if ( $r->responseCode != 200 ) {
      return undef;
   }
   $response = from_json( $r->responseContent );
   if ( ! $response->{json}->{data} ) {
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
   if ( $post->{data}->{domain} !~ /(deviantart\.com|fav\.me)$/ ) {
      next;
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
   my $mirror = make_mirror( $imgur, $deviantart, $post->{data}->{url} );
   if ( ! $mirror ) { 
      $errors = 1;
      next;
   }
   if ( $mirror eq "TOO_LARGE" ) {
      next;
   }

   # Make comment in submission post
   if ( ! make_reddit_comment( $reddit, $post->{data}->{name}, $mirror->{data}->{id} ) ) {
      # Don't leave the now useless mirror up
      delete_mirror( $imgur, $mirror->{data}->{deletehash} );
      $errors = 1;
      next;
   }

   log_mirror( $mirror, $post );
}

if ( ! $errors ) {
   set_lastrun( $now );
}
