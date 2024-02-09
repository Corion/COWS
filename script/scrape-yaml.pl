#!perl
use 5.020;
use experimental 'try';
use feature 'signatures';
no warnings 'experimental::signatures';
use Carp 'croak';

# Read merchant whitelist from config?
use URI;
use YAML 'LoadFile';
use Filesys::Notify::Simple;
use File::Spec;
use JSON 'encode_json';
use Text::Table;
use XML::Feed;
use DateTime;
use DateTime::Format::ISO8601;
use COWS::UserAgent;
use Getopt::Long;

use lib '../App-moveyear/lib';
use Date::Find 'guess_ymd';

GetOptions(
    'config|c=s'      => \my $config_file,
    'interactive|i'   => \my $interactive,
    'output-type|t=s' => \my $output_type,
    'output-file|o=s' => \my $output_file,
    'scrape-item|s=s' => \my $scrape_item,
    'debug|d'         => \my $debug,
    'verbose'         => \my $verbose,
);

$output_type //= 'table';

my %default_start_rules = (
    table => 'items',
    rss   => 'rss',
    json  => 'items',
    # output via TT / Mojolicious::Template?
);
$scrape_item //= $default_start_rules{ $output_type };
if( ! $scrape_item ) {
    if( ! exists $default_start_rules{ $output_type }) {
        die "Unknown output type '$output_type'";
    };
    die "Need a start rule." unless $scrape_item;
}

sub load_config( $config_file ) {
    my $config = LoadFile( $config_file );
    if( ! $config->{items} ) {
        die "$config_file: No '$config->{$scrape_item}' section found";
    }
    return $config;
}

sub create_scraper( $config ) {
    my $scraper = COWS::UserAgent->new(
        base    => $config->{base},
        debug => $debug,
    );
}

sub update_file( $filename, $new_content ) {
    my $content;
    if( -f $filename ) {
        open my $fh, '<', $filename
            or die "Couldn't read '$filename': $!";
        binmode $fh;
        local $/;
        $content = <$fh>;
    };

    if( $content ne $new_content ) {
        if( open my $fh, '>', $filename ) {
            binmode $fh;
            print $fh $new_content;
        } else {
            warn "Couldn't (re)write '$filename': $!";
        };
    };
}

sub output( $str, $filename ) {
    if( defined $filename ) {
        update_file( $filename => $str );
    } else {
        say $str
    }
}

my %cache;
sub scrape_pages($config, @items) {
    my $scraper = create_scraper( $config );

    my @rows;
    for my $item (@items) {
        push @rows, $scraper->scrape(
            ua => $scraper,
            cache => \%cache,
            start_rule => $scrape_item,
            config => $config,
            item => $item,
        )->@*;
    };
    output_data( $config, $output_type, \@rows );
}

sub output_data( $config, $output_type, $rows ) {
    if( $output_type eq 'table' ) {

        # Flatten the results
        @$rows = map { @{ $_->{$scrape_item }} } @$rows;

        my @columns;
        if( ! $config->{columns}) {
            my %columns;
            for(@$rows) {
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

        my $res = Text::Table->new(@columns);
        $res->load(map { [@{ $_ }{ @columns }] } @$rows);

        output( $res, $output_file );

    } elsif( $output_type eq 'rss' ) {
        my $f = $rows->[0];
        # we only ever output a single feed - maybe we should output multiple
        # files, or mush all the feeds into one?!

        my $feed = XML::Feed->new( 'Atom', version => 2 );

        $feed->id($f->{title});
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

        output( $feed->as_xml, $output_file );

    } elsif( $output_type eq 'json' ) {
        output( encode_json($rows), $output_file);
    } else {
        die "Unknown output type '$output_type'";
    }
}

sub do_scrape_items ( @items ) {
    my $config = load_config( $config_file );
    scrape_pages( $config => @items );
}

try {
    do_scrape_items( @ARGV );
} catch($e) {
    warn $e;
}
if( $interactive ) {
    $config_file = File::Spec->rel2abs( $config_file );
    my $watcher = Filesys::Notify::Simple->new( [$config_file] );
    $watcher->wait(sub(@ev) {
        for( @ev ) {
            # re-filter, since we maybe got more than we wanted
            if( $_->{path} eq $config_file ) {
                try {
                    do_scrape_items(@ARGV)
                } catch($e) {
                    warn $e;
                }
            #} else {
            #    warn "Ignoring change to $_->{path}";
            }
        };
    }) while 1;
}
