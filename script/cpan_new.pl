#!/usr/bin/env perl

use strict;
use warnings;

use constant MARKER_FILE => "$ENV{HOME}/.cpan_new_timestamp";

use XML::Simple;
use Time::Piece;
use Data::Dumper;

use JSON;
use Try::Tiny;
use Config::Tiny;

use DDP;
use AnyEvent;
use Getopt::Long;
use AnyEvent::HTTP;
use Mastodon::Client;

use Log::Any qw( $log );
use Log::Any::Adapter;
Log::Any::Adapter->set( 'Stderr',
  category => 'Mastodon',
  log_level => 'debug',
);

use Path::Tiny qw( path );
my $timestamp = path "$ENV{HOME}/.cpan_new_timestamp";

our @QUEUE;

my ($configfile) = @ARGV;
$configfile //= "$ENV{HOME}/.cpan_new.ini";

my $config = (defined $configfile)
  ? Config::Tiny->read( $configfile )->{_} : {};

my $client = Mastodon::Client->new({
  %{$config},
  coerce_entities => 1,
});

my $w; $w = AE::timer 1, 30, sub {

  http_get "https://metacpan.org/feed/recent", sub {
    my ($data, $headers) = @_;

    unless ($data) {
      $log->infof(Dumper $headers);
      return;
    }

    my $xml = XMLin($data);

    foreach my $item (@{$xml->{item}}) {
      my $item_timestamp = Time::Piece
        ->strptime( $item->{'dc:date'}, '%Y-%m-%dT%H:%M:%SZ' )
        ->epoch;

      next if LATEST_TIMESTAMP() >= $item_timestamp;

      LATEST_TIMESTAMP($item_timestamp);

      my $title = sprintf "%-.80s", $item->{title};

      toot(sprintf "%s %s by %s\n%s\n%s",
        '@jjatria@mastodon.cloud',
        $title,
        $item->{'dc:creator'},
        $item->{description},
        $item->{link}
      );
    }
  }
};

my $qwatcher; $qwatcher = AE::timer 5, 300, sub {
    my $string = shift @QUEUE;
    tweet($string) if $string;
};

$log->debug('Start crawling');
AE::cv->recv;

sub toot {
  my $string = shift;

  p my $response = try {
    $log->debug($string);
    $client->post_status( $string, { visibility => 'direct' } );
  }
  catch {
    $log->warn('Died');
    push @QUEUE, $string;
  };
}

sub LATEST_TIMESTAMP {
  my $epoch = shift;

  return ($epoch)
    ? $timestamp->touchpath($epoch)
    : $timestamp->stat->[9];
}

__END__

