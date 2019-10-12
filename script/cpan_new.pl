#!/usr/bin/env perl

use strict;
use warnings;
use feature 'state';

use Config::Tiny;
use Data::Dumper;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Log::Any qw( $log );
use Log::Any::Adapter;
use Mastodon::Client;
use Net::Async::HTTP;
use Path::Tiny qw( path );
use Syntax::Keyword::Try;
use Time::Piece;
use XML::Tiny::DOM;

Log::Any::Adapter->set( 'Stderr',
    category => 'Mastodon',
    log_level => 'debug',
);

my $config = do {
    my $configfile = path( shift // '~/.cpan_new.ini' );
    my $config = Config::Tiny->read( $configfile );
    $config->{_};
};

my $client = Mastodon::Client->new(
    coerce_entities => 1,
    %{ $config // {} },
);

my $loop = IO::Async::Loop->new;

my $ua = Net::Async::HTTP->new( fail_on_error => 1 );
$loop->add($ua);

my $timer = IO::Async::Timer::Periodic->new(
    first_interval => 1,
    interval       => 30,
    on_tick        => sub {
        $ua->do_request(
            uri => 'https://metacpan.org/feed/recent',
            on_response => sub {
                my $res = shift;

                my $dom;
                try {
                    my $body = $res->content;
                    open my $fh, '<', \$body;
                    $dom = XML::Tiny::DOM->new($fh);
                }
                catch {
                    $log->errorf('Could not parse XML: %s', $_);
                    $log->debug( $res->content );
                    return;
                }

                for my $item ( $dom->item('*') ) {
                    my $item_timestamp = Time::Piece
                        ->strptime( $item->${\'dc:date'}, '%Y-%m-%dT%H:%M:%SZ' )
                        ->epoch;

                    next if latest_timestamp() >= $item_timestamp;

                    latest_timestamp($item_timestamp);

                    my $title = sprintf '%-.80s', $item->title;

                    toot(
                        sprintf "%s by %s\n%s\n%s",
                        $title,
                        $item->${\'dc:creator'},
                        $item->description // '',
                        $item->link
                    );
                }
            },
            on_error => sub {
                $log->warn( Dumper shift );
            },
        );
    },
);

$timer->start;
$loop->add($timer);

{
    my @QUEUE;

    sub toot {
        my $string = shift;
        my ($brief) = split /\n/, $string;

        try {
            $log->debug( $brief );
            $client->post_status( $string, { visibility => 'unlisted' } );
        }
        catch {
            $log->warnf( '!%s: %s', $brief, $_ );
            push @QUEUE, $string;
        }
    }

    my $watcher = IO::Async::Timer::Periodic->new(
        first_interval => 5,
        interval       => 300,
        on_tick        => sub {
            my $string = shift @QUEUE;
            toot($string) if $string;
        },
    );

    $watcher->start;

    $loop->add($watcher);
}

$log->debug('Start crawling');
$loop->run;

sub latest_timestamp {
    my $epoch = shift;

    state $timestamp = path '~/.cpan_new_timestamp';

    $timestamp->touchpath unless -e $timestamp;

    return ($epoch)
        ? $timestamp->touch($epoch)
        : $timestamp->stat->[9];
}
