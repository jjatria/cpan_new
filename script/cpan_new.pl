#!/usr/bin/env perl

use strict;
use warnings;

use XML::Simple;
use Time::Piece;
use Data::Dumper;

use JSON;
use Try::Tiny;
use Config::Tiny;

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
            $log->warnf(Dumper $headers);
            return;
        }

        my $xml = try {
            XMLin($data);
        }
        catch {
            $log->errorf('Could not parse XML: %s', $_);
            $log->debug($data);
            return { item => [] };
        };

        foreach my $item (@{$xml->{item}}) {
            my $item_timestamp = Time::Piece
                ->strptime( $item->{'dc:date'}, '%Y-%m-%dT%H:%M:%SZ' )
                ->epoch;

            next if LATEST_TIMESTAMP() >= $item_timestamp;

            LATEST_TIMESTAMP($item_timestamp);

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

    return try {
        $log->debug( $brief );
        $client->post_status( $string, { visibility => 'unlisted' } );
    }
    catch {
        $log->warnf( '!%s: %s', $brief, $_ );
        push @QUEUE, $string;
    };
}

sub LATEST_TIMESTAMP {
    my $epoch = shift;

    $timestamp->touchpath unless -e $timestamp;

    return ($epoch)
        ? $timestamp->touch($epoch)
        : $timestamp->stat->[9];
}

__END__
