use 5.020;
use COWS::Crawler;
use feature 'signatures';
no warnings 'experimental::signatures';

use COWS 'scrape';
use URI;
use lib '../Term-Output-List/lib';
use Term::Output::List;

use Getopt::Long;
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

GetOptions(
    'config|c=s'      => \my $config_file,
    'interactive|i'   => \my $interactive,
    'output-type|t=s' => \my $output_type,
    'output-file|o=s' => \my $output_file,
    'scrape-item|s=s' => \my $scrape_item,
    'debug|d'         => \my $debug,
    'verbose'         => \my $verbose,
    'not-above=s'     => \my $top,
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

# The progress output
my $printer = Term::Output::List->new();
my @scoreboard;

sub status($res, $r) {
    my $size = $res->content->progress;
    my $url = $r->{req}->req->url;
    my $len = $res->headers->content_length;

    my $viz = $url;
    # Get terminal size
    if( length $viz > 80 ) {
        substr( $viz, 77 ) = '...';
    }

    return sprintf "% 3d %s %s", $size == $len ? 100 : int($size / ($len / 100)), $url;
}

sub output_scoreboard() {
    #my $debug = sprintf "%d requests, %d pending", scalar(keys %scoreboard), scalar $crawler->queue->@*;
    $printer->output_list(
        #$debug,
        map { status( @$_ ) } @scoreboard
    );
}

sub msg($msg) {
    $printer->output_permanent($msg);
    output_scoreboard();
}

sub load_config( $config_file ) {
    my $config = LoadFile( $config_file );
    if( ! $config->{items} ) {
        die "$config_file: No 'items' section found";
    }
    return $config;
}

sub create_crawler( $config ) {
    my $crawler = COWS::Crawler->new(
        #base    => $config->{base},
        debug => $debug,
    );

    $crawler->on('progress' => sub($c, $r, $res) {
        return unless my $len = $res->headers->content_length;

        # Check if we already have this request in our list
        if( ! grep { $_->[0] == $res and $_->[1] == $r } @scoreboard) {
            push @scoreboard, [$res,$r]
        }

        output_scoreboard();
    });

    $crawler->on('error' => sub($c, $r) {
        msg( sprintf "Couldn't fetch %s", $r->{req}->req->url );
        output_scoreboard();
    });

    # remove things on complete
    $crawler->on('finish' => sub($c, $r, $res) {
        @scoreboard = grep { $_->[0] != $res or $_->[1] != $r } @scoreboard;
        #msg( sprintf "Finished %s", $r->{req}->req->url );
        output_scoreboard();
    });

    return $crawler
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

# We want three kinds of actions
# * follow(url) - enqueue+scrape the next page
# * download(url,filename) - download the URL to a file (filename is optional?)
# * include(url) - (also) scrape the next page and include it here

sub handle_follow( $crawler, $page, $url ) {
    # Should we warn about bad URLs?
    next unless $url =~ /^http/i;

    # Should we log that we skip an URL?
    next unless $url =~ /^\Q$top\E/i;

    my $u = $url;
    my $info = {
        url => $u,
        from => $page->{info}->{url},
    };

    if(
        $crawler->submit_request({info => $info, GET => "$url"})
    ) {
        #msg("Queueing $url");
        #msg( sprintf "Queueing %s (%x, %x)", $r->{req}->req->url, $res, $r );
    } else {
        #msg("Skipping $url");
    }
}

sub handle_download( $crawler, $page, $url, $filename=undef ) {
    # launch a download
    my $info = {
        url => $url,
        from => $page->{info}->{url},
    };
    my $filename;
    if( $url =~ m!\b([^/?=]+\.jpe?g)\b! ) {
        $filename = $1;
    } else {
        die "Couldn't guess filename from '$url'";
    }
    next if -e $filename;
    # resume downloads?

    $crawler->submit_download({info => $info, GET => "$url",
    #headers => {
    #    Referer => $page->{info}->{url},
    #    cookies?
    #}
    } => $filename);
}

my %actions = (
    follow   => \&handle_follow,
    download => \&handle_download,
);

sub execute_actions( $crawler, $page, $i ) {
    if( ! ref $i ) {
        # ignore

    } elsif( ref $i eq 'HASH' ) {
        if( exists $i->{action}) {

            my $actions;
            if( ! ref $i->{action}) {
                $actions = [$i->{action}]
            } else {
                $actions = $i->{action};
            };

            for my $action ( @$actions ) {
                if( $action !~ /^(\w+)\s*\((.*)\)$/ ) {
                    die "Malformed action: '$action'";
                };
                my ($name, $args) = ($1,$2);
                my @args = ($args =~ /"((?:[^\"]|\\.)+)"/g);

                if( ! exists $actions{ $name }) {
                    die "Unknown action '$name'";
                }

                for my $val ($i->{$args[0]}->@*) {
                    $actions{ $name }->( $crawler, $page, $val );
                };

                #say "Action: $name $args[0] $i->{$args[0]}";
            }
        };
        for my $k (grep { $_ ne 'action' } keys %$i) {
            execute_actions( $crawler, $page, $i->{ $k } );
        }

    } elsif( ref $i eq 'ARRAY' ) {
        execute_actions( $crawler, $page, $_ ) for @$i;

    }
}

my %cache;
sub scrape_pages($config, @items) {
    my $crawler = create_crawler( $config );

    my @rows;
    for my $url (@items) {
        $crawler->submit_request({ GET => $url, info => { url => $url }} ) ;
    }

    my @res;
    while( my ($page) = $crawler->next_page ) {
        # $page contains the decoded body
        # or should that simply be the response?!

        # ->scrape acts on that body (and warns if the page is not text/html
        # ->json decodes JSON
        # ->info contains user info

        # If it is a page that results in navigation, enqueue the proper navigation
        # submit more navigation
        #my @links = $page->scrape( [ { name => link, query => 'a@href', munge => ['absolute'], } ] );
        my $body = $page->{res}->body;
        my $url = $page->{req}->req->url;
        #msg( sprintf "Handling %s (%x, %x)", $page->{req}->req->url, $page->{res}, $page->{req} );
        my $status = $page->{res}->code;
        if( ! $body ) {
            # skip
            #die "Empty response for " . $page->{req}->req->url;
            next;
        }

        if( $status !~ /[23]\d\d/ ) {
            msg( "$status $url" );
        }

        # Skip non-HTML content...

        my $info = scrape( $body,
        [
        { name => 'talk',
        query => '//tbody/tr',
        fields => [
            #{ name => 'next', query => '//a[img[@id="picture"]]/@href', munge => ['url'], tag => 'action:follow("next")'},
            { name => 'time', single => 1, query => './td[1]' },
            { name => 'date', query => '/html//h2[following-sibling::div][2]', single => 1, munge => 'date'},
            { name => 'speaker', single =>1, query => './td[2]//a[1]' },
            { name => 'speaker_link', single => 1, query => './td[2]/a[1]/@href', munge => 'url' },
            { name => 'talkname', single => 1, query => './td[2]/a[2]/b' },
            { name => 'talkname_link', single => 1, query => './td[2]/a[2]/@href', munge => 'url' },
        ],
        },
        { name => 'link',
        query => '//a[contains(@href,"?day=") and not(contains(@href,"language="))]/@href',
        tag => 'action:follow("link")',
        munge => 'url',
        },
        ], {
            url => "" . $page->{req}->req->url,
        });
        execute_actions( $crawler, $page, $info );

        # Extract all the information we want
        #my $info = $page->scrape($rules, ...);

        push @rows, $info;

    }
    # Well, not output, clear, but OK :D
    output_scoreboard();
    output_data( $config, $output_type, \@rows );
}

sub do_scrape_items ( @items ) {
    #my $config = load_config( $config_file );
    my $config = {};
    scrape_pages( $config => @items );
}

sub output( $str, $filename ) {
    if( defined $filename ) {
        update_file( $filename => $str );
    } else {
        say $str
    }
}

sub output_data( $config, $output_type, $rows ) {
    if( $output_type eq 'table' ) {
        use Data::Dumper;
        warn $scrape_item;
        warn Dumper $rows;

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

do_scrape_items( @ARGV );
if( $interactive ) {
    $config_file = File::Spec->rel2abs( $config_file );
    my $watcher = Filesys::Notify::Simple->new( [$config_file] );
    $watcher->wait(sub(@ev) {
        for( @ev ) {
            # re-filter, since we maybe got more than we wanted
            if( $_->{path} eq $config_file ) {
                eval {
                    do_scrape_items(@ARGV)
                };
                warn $@ if $@;
            #} else {
            #    warn "Ignoring change to $_->{path}";
            }
        };
    }) while 1;
}

#use Data::Dumper;
#say Dumper \@res;
