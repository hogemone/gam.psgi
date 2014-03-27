#

use strict;
use warnings;

use Coro;
use Coro::LWP;
use Coro::AnyEvent;
use Digest::MD5 qw(md5_hex);
use HTTP::MobileAgent;
use LWP::UserAgent;
use Plack::Request;
use URI::Escape;

$AnyEvent::HTTP::MAX_PER_HOST = 100;

my $timeout          = 2;
my $afer             = 0.5;
my $interval         = 1;
my $utm_gif_location = "http://www.google-analytics.com/__utm.gif";
my @GIF_DATA         = (
  0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0xff,
  0x00, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3b
);

my $handler = sub {
  my $env = shift;
  my $req = Plack::Request->new($env);

  my $cv = AE::cv;

  async_pool
  {
    local $ENV{REMOTE_ADDR} = $env->{REMOTE_ADDR};
    local $ENV{HTTP_HOST}   = $env->{HTTP_HOST};

    my $domain  = uri_unescape( $req->param('domain') ) ||;
    my $referer = uri_unescape( $req->param('utmr') )   || '-';
    my $path    = uri_unescape( $req->param('utmp') )   || '';
    my $account = $req->param('utmac')                  || '';
    my $guid
      = $env->{'HTTP_X_DCMGUID'}
      || $env->{'HTTP_X_UP_SUBNO'}
      || $env->{'HTTP_X_JPHONE_UID'}
      || $env->{'HTTP_X_EM_UID'}
      || '';
    my $message
      = $guid ne '' ? $guid . $account : $env->{'HTTP_USER_AGENT'} . int( rand(0x7fffffff) );
    my $visitor_id = '0x' . substr( md5_hex($message), 0, 16 );
    my $ip = $env->{'REMOTE_ADDR'} =~ /^((\d{1,3}\.){3})\d{1,3}$/ ? $ip = $1 . '0' : undef;
         $domain
      or $path
      or $account
      or $visitor_id
      or $ip
      or return $cv->send( [ 403, [ 'Content-Type' => 'text/plain' ], ['Forbidden'] ] );

    my $gauri
      = $utm_gif_location . '?'
      . 'utmwv='
      . VERSION
      . '&utmn='
      . int( rand(0x7fffffff) )
      . '&utmhn='
      . uri_escape($domain)
      . '&utmr='
      . uri_escape($referer)
      . '&utmp='
      . uri_escape($path)
      . '&utmac='
      . $account
      . '&utmcc=__utma%3D999.999.999.999.999.1%3B'
      . '&utmvid='
      . $visitor_id
      . '&utmip='
      . $ip;
    my $request = HTTP::Request->new( $req->method, $gauri );

    my $ua = LWP::UserAgent->new;
    $ua->default_header( 'Accepts-Language' => $env->{'HTTP_ACCEPT_LANGUAGE'} );
    $ua->agent( $env->{'HTTP_USER_AGENT'} );

    my $coro = $Coro::current;
    $coro->desc('LWP');
    $coro->{timeout_at} = Time::HiRes::time() + $timeout;
    $coro->on_destroy(
      sub {
        my $message = shift;
        warn sprintf "coro:%s cancel because %s", $coro->desc, $message;
        if ( $message eq 'timeout' )
        {
          return $cv->send( [ 200, [ 'Content-Type' => 'text/plain' ], ['Timeout'] ] );
        }
      }
    );
    
    my $w = AnyEvent->timer(
      after    => $after,
      interval => $interval,
      cb       => sub {
        my $now = Time::HiRes::time;
        my @lwp_coro = grep { $_->desc eq 'LWP' } Coro::State::list;
        warn sprintf "%s lwp coro found.", scalar @lwp_coro;
        for my $coro (@lwp_coro)
        {
          if ( $now > $coro->{timeout_at} )
          {
            $coro->cancel('timeout');
          }
        }
        if ( @lwp_coro == 0 )
        {
          return;
        }
      }
    );

    {
      my $response = $ua->request($request);
      $cv->send(
        [ $response->code, [ 'Content-Type' => 'image/gif' ], [ pack( 'C35', @GIF_DATA ) ] ] );
    }

    $w    = undef;
    $coro = undef;
    Coro::schedule;

  };

  return sub {
    my $start_response = shift;
    $cv->cb(
      sub {
        my $recv = shift->recv;
        $start_response->($recv);
      }
    );
  }

}
