use 5.020;
use COWS::Crawler;
use feature 'signatures';
no warnings 'experimental::signatures';

use COWS 'scrape';
use URI;

#
my $crawler = COWS::Crawler->new(
    # ua => my async ua
);

use lib '../Term-Output-List/lib';
use Term::Output::List;
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

$crawler->on('progress' => sub($c, $r, $res) {
    return unless my $len = $res->headers->content_length;

    # Check if we already have this request in our list
    if( ! grep { $_->[0] == $res and $_->[1] == $r } @scoreboard) {
        push @scoreboard, [$res,$r]
    }

    output_scoreboard();
});

$crawler->on('error' => sub($c, $r) {
    $printer->output_permanent( sprintf "Couldn't fetch %s", $r->{req}->req->url );
    output_scoreboard();
});

# remove things on complete
$crawler->on('finish' => sub($c, $r, $res) {
    @scoreboard = grep { $_->[0] == $res and $_->[1] == $r } @scoreboard;
    #$printer->output_permanent($r->{req}->req->url);
    output_scoreboard();
});

my $top = shift @ARGV;
if( ! @ARGV ) {
    push @ARGV, $top;
}

# We want three kinds of actions
# * follow(url) - enqueue+scrape the next page
# * download(url,filename) - download the URL to a file (filename is optional?)
# * include(url) - (also) scrape the next page and include it here

sub handle_follow( $page, $url ) {
    # Should we warn about bad URLs?
    next unless $url =~ /^http/i;

    # Should we log that we skip an URL?
    next unless $url =~ /^\Q$top\E/i;

    my $u = $url;
    my $info = {
        url => $u,
        from => $page->{info}->{url},
    };
    $crawler->submit_request({info => $info, GET => "$url"});
}

sub handle_download( $page, $url, $filename=undef ) {
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

sub execute_actions( $page, $i ) {
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
                    $actions{ $name }->( $page, $val );
                };

                #say "Action: $name $args[0] $i->{$args[0]}";
            }
        };
        for my $k (grep { $_ ne 'action' } keys %$i) {
            execute_actions( $page, $i->{ $k } );
        }

    } elsif( ref $i eq 'ARRAY' ) {
        execute_actions( $page, $_ ) for @$i;

    }
}

for my $url (@ARGV) {
    $crawler->submit_request({ GET => $url, info => { url => $url }} ) ;
}
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
    my $status = $page->{res}->code;
    if( ! $body ) {
        # skip
        #die "Empty response for " . $page->{req}->req->url;
        next;
    }

    if( $status !~ /[23]\d\d/ ) {
        #say "$status $url";
    }

    # Skip non-HTML content...

    my $links = scrape( $body,
    [
        { name => 'next', query => '//a[img[@id="picture"]]/@href', munge => ['url'], tag => 'action:follow("next")'},
        { name => 'image', query => '//img[@id="picture"]/@src', munge => ['url'], tag => 'action:download("image")'},
    ], {
        url => "" . $page->{req}->req->url,
    });
    execute_actions( $page, $links );

    #$crawler->submit_request($request);
    # Extract all the information we want
    #my $info = $page->scrape($rules, ...);

    # look at (say) $info->{type} to find what kind of page we are on
    # Download and store all images - this is something the crawler/UA also handle,
    # so we can easily parallelize this
    #my $links = $page->scrape( [ { name => link, query => 'img@src', munge => ['absolute'], } ] );
    #for my $i ($links->{link}->@*) {
    #   $crawler->submit_download( info => $info, $i => $target_filename );
    #}
}
