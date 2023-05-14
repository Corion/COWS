#!perl
use 5.020;

package Scraper::FromYaml 0.1;
use 5.020;
use feature 'signatures';

use Moo 2;
no warnings 'experimental::signatures';

use URI;
use lib '/home/corion/Projekte/Corion-Scraper/lib';
use COWS 'scrape';
use Mojo::UserAgent;
use Carp 'croak';

has 'ua' => (
    is => 'lazy',
    default => sub {
        Mojo::UserAgent->new(
            max_redirects => 2,
        );
    }
);

has 'base' => (
    is => 'ro',
);

has 'config' => (
    is => 'ro',
);

has 'mungers' => (
    is => 'ro',
);

sub make_url( $self, $id ) {
    my $base = $self->base;
    if( $base =~ /%/ ) {
        $base = sprintf $base, $id
    }
    return $base
}

sub fetch_data( $self, $id) {
    my $res = $self->ua->get( $self->make_url($id))->result;
    croak "Code " . $res->code unless $res->code =~ /^2..$/;
    return $res->body
}

sub parse( $self, $rules, $id_or_html ) {
    my $html = $id_or_html;
    if( $id_or_html !~ /^</ ) {
        $html = $self->fetch_data( $id_or_html );
    };
    return scrape( $html, $rules, { debug => 1, mungers => $self->mungers });
}

package main;

use Getopt::Long;

# Read merchant whitelist from config?
use YAML 'LoadFile';
use Filesys::Notify::Simple;
use File::Spec;
use JSON;
use XML::Feed;
use DateTime;
use DateTime::Format::ISO8601;

GetOptions(
    'config|c=s'      => \my $config_file,
    'interactive|i'   => \my $interactive,
    'output-type|o=s' => \my $output_type,
    'debug|d'         => \my $debug,
);

sub load_config( $config_file ) {
    my $config = LoadFile( $config_file );
    if( ! $config->{items} ) {
        die "$config_file: No 'items' section found";
    }
    return $config;
}

sub extract_price( $text ) {
    $text =~ s/.*?(\d+)[.,](\d\d).*/$1.$2/r
}

sub compress_whitespace( $text ) {
    $text =~ s!\s+! !msg;
    $text =~ s!^\s+!!;
    $text =~ s!\s+$!!;
    return $text
}

my %handlers = (
    extract_price => \&extract_price,
    compress_whitespace => \&compress_whitespace,
);

sub create_scraper( $config ) {
    my $scraper = Scraper::FromYaml->new(
        mungers => \%handlers,
        base => $config->{base},
        debug => $debug,
    );
}

my %cache;
sub scrape_pages($config, @items) {
    my $scraper = create_scraper( $config );

    my $start_rule = 'items';
    if( $output_type eq 'rss' ) {
        $start_rule = 'rss';
    }

    my @rows;
    for my $item (@items) {
        my $html = $cache{ $item } // $scraper->fetch_data( $item );
        my $data = $scraper->parse($config->{$start_rule}, $html);
        if( ref $data eq 'HASH' ) {
            push @rows, $data;
        } else {
            push @rows, @{$data};
        }
    }

    if( $output_type eq 'table' ) {

        my @columns;
        if( ! $config->{columns}) {
            my %columns;
            for(@rows) {
                for my $k (keys %$_) {
                    $columns{ $k } = 1;
                }
            }
            @columns = sort keys %columns;
        } else {
            @columns = $config->{columns}->@*;
        }

        # Should we roll-up/flatten anything if the output format is text/table
        # instead of JSON ?!

        # Can we usefully output things as RSS ?!
        use Text::Table;
        my $res = Text::Table->new(@columns);
        $res->load(map { [@{ $_ }{ @columns }] } @rows);
        say $res;
    } elsif( $output_type eq 'rss' ) {
        # XML::Feed
        my $f = $rows[0];

        my $feed = XML::Feed->new( 'Atom', version => 2 );

        $feed->id("http://".time.rand()."/");
        $feed->title($f->{title});
        #$feed->link(...); # self-url!
        #$feed->self_link($cgi->url( -query => 1, -full => 1, -rewrite => 1) );
        #$feed->modified(DateTime->now);

        for my $post (@{ $f->{entries} }) {
            my $entry = XML::Feed::Entry->new();
            $entry->id($post->{id});
            $entry->link($post->{link});
            $entry->title($post->{title});
            $entry->summary($post->{summary} // "");
            $entry->content($post->{content} );

            my $p = DateTime::Format::ISO8601->new;
            $entry->modified($p->parse_datetime( $post->{modified} ));

            $entry->author($post->{author});
            $feed->add_entry($entry);
        }

        say $feed->as_xml;
    }
}

sub do_scrape_items ( @items ) {
    my $config = load_config( $config_file );
    scrape_pages( $config => @items );
}

do_scrape_items( @ARGV );
if( $interactive ) {
    $config_file = File::Spec->rel2abs( $config_file );
    my $watcher = Filesys::Notify::Simple->new( [$config_file] );
    $watcher->wait(sub(@ev) {
        for( @ev ) {
            # re-filter, since we maybe got more than we wanted
            if( $_->{path} eq $config_file ) {
                do_scrape_items(@ARGV)
            #} else {
            #    warn "Ignoring change to $_->{path}";
            }
        };
    }) while 1;
}
