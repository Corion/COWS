#!perl
use 5.020;
use Getopt::Long;

# Read merchant whitelist from config?
use URI;
use YAML 'LoadFile';
use Filesys::Notify::Simple;
use File::Spec;
use JSON;
use XML::Feed;
use DateTime;
use DateTime::Format::ISO8601;
use COWS::UserAgent;

GetOptions(
    'config|c=s'      => \my $config_file,
    'interactive|i'   => \my $interactive,
    'output-type|t=s' => \my $output_type,
    'output-file|o=s' => \my $output_file,
    'debug|d'         => \my $debug,
);

sub load_config( $config_file ) {
    my $config = LoadFile( $config_file );
    if( ! $config->{items} ) {
        die "$config_file: No 'items' section found";
    }
    return $config;
}

sub extract_price( $text, $node, $info ) {
    $text =~ s/.*?(\d+)[.,](\d\d).*/$1.$2/r
}

sub compress_whitespace( $text, $node, $info ) {
    $text =~ s!\s+! !msg;
    $text =~ s!^\s+!!;
    $text =~ s!\s+$!!;
    return $text
}

sub url( $text, $node, $info ) {
    use Data::Dumper;
    die "No URL in " . Dumper $info
        unless exists $info->{url};
    $text = "" . URI->new_abs( $text, $info->{url} );
}

my %handlers = (
    extract_price => \&extract_price,
    compress_whitespace => \&compress_whitespace,
    url => \&url,
);

sub create_scraper( $config ) {
    my $scraper = COWS::UserAgent->new(
        mungers => \%handlers,
        base => $config->{base},
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

    my $start_rule = 'items';
    if( $output_type eq 'rss' ) {
        $start_rule = 'rss';
    }

    my @rows;
    for my $item (@items) {
        my $url = $scraper->make_url( $item );

FETCH:
        my $html = $cache{ $url } // $scraper->fetch( "$url" );

        # first check if we need to navigate on the page to the latest page:
        my $data = $scraper->parse($config->{'navigation'}, $html, { url => $url });
        if( $data->{refetch_page} ) {
            my $latest = URI->new_abs( $data->{refetch_page}, $url );
            if( $latest ne $url ) {
                $url = $latest;
                goto FETCH;
            }
        }

        my $real_data = $scraper->parse($config->{$start_rule}, $html, { url => $url });
        if( ref $real_data eq 'HASH' ) {
            push @rows, $real_data;
        } else {
            push @rows, @{$real_data};
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

        output( $res, $output_file );

    } elsif( $output_type eq 'rss' ) {
        # XML::Feed
        my $f = $rows[0];

        my $feed = XML::Feed->new( 'Atom', version => 2 );

        $feed->id($f->{title}->{title});
        $feed->title($f->{title}->{title});
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
