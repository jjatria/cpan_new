#!/usr/bin/env perl

use strict;
use warnings;
use feature 'state';

use AnyEvent::HTTP;
use AnyEvent;
use Config::Tiny;
use Data::Dumper;
use Log::Any qw( $log );
use Log::Any::Adapter;
use Mastodon::Client;
use Path::Tiny qw( path );
use Syntax::Keyword::Try;
use Time::Piece;
use XML::Tiny 'parsefile';

Log::Any::Adapter->set( 'Stderr',
    category => 'Mastodon',
    log_level => 'debug',
);

our @QUEUE;

my $config = do {
    my $configfile = path( shift // '~/.cpan_new.ini' );
    my $config = Config::Tiny->read( $configfile );
    $config->{_};
};

my $client = Mastodon::Client->new(
    coerce_entities => 1,
    %{ $config // {} },
);

my $w; $w = AE::timer 1, 30, sub {

    http_get "https://metacpan.org/feed/recent", sub {
        my ($data, $headers) = @_;

        unless ($data) {
            $log->warnf(Dumper $headers);
            return;
        }

        my $xml;

        try {
            open my $fh, '<', \$data;
            $xml = shift @{ parsefile $fh };
        }
        catch {
            $log->errorf('Could not parse XML: %s', $_);
            $log->debug($data);
            return;
        }

        foreach my $item (@{$xml->{item}}) {
            my $item_timestamp = Time::Piece
                ->strptime( $item->{'dc:date'}, '%Y-%m-%dT%H:%M:%SZ' )
                ->epoch;

            next if latest_timestamp() >= $item_timestamp;

            latest_timestamp($item_timestamp);

            my $title = sprintf "%-.80s", $item->{title};

            toot(sprintf "%s by %s\n%s\n%s",
                $title,
                $item->{'dc:creator'},
                $item->{description} // '',
                $item->{link}
            );
        }
    }
};

my $qwatcher; $qwatcher = AE::timer 5, 300, sub {
    my $string = shift @QUEUE;
    toot($string) if $string;
};

$log->debug('Start crawling');
AE::cv->recv;

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

sub latest_timestamp {
    my $epoch = shift;

    state $timestamp = path '~/.cpan_new_timestamp';

    $timestamp->touchpath unless -e $timestamp;

    return ($epoch)
        ? $timestamp->touch($epoch)
        : $timestamp->stat->[9];
}
