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

my %scoreboard;
$crawler->on('progress' => sub($c, $r, $res) {
    return unless my $len = $res->headers->content_length;
    my $size = $res->content->progress;
    my $url = $r->{req}->req->url;
    $scoreboard{ $res } = sprintf "% 3d%s %s", $size == $len ? 100 : int($size / ($len / 100)), $url;

    #$printer->output_list(map { $scoreboard{ $_ } } sort keys %scoreboard);
});

$crawler->on('error' => sub($c, $r) {
    warn sprintf "Couldn't fetch %s", $r->{req}->req->url
});

# remove things on complete
$crawler->on('finish' => sub($c, $r, $res) {
    delete $scoreboard{ $res };
    $printer->output_permanent($r->{req}->req->url);
    $printer->output_list(map { $scoreboard{ $_ } } sort keys %scoreboard);
});

# We want three kinds of actions
# * follow(url) - enqueue+scrape the next page
# * download(url,filename) - download the URL to a file (filename is optional?)
# * include(url) - (also) scrape the next page and include it here

sub execute_actions( $i ) {
    if( ! ref $i ) {
    } elsif( ref $i eq 'HASH' ) {
        if( exists $i->{action}) {
            if( $i->{action} !~ /^(\w+)\s*\((.*)\)$/ ) {
                die "Malformed action: '$i->{action}'";
            };
            my ($name, $args) = ($1,$2);
            my @args = ($args =~ /"((?:[^\"]|\\.)+)"/g);

            say "Action: $name $args[0] $i->{$args[0]}";
        };
        for my $k (grep { $_ ne 'action' } keys %$i) {
            execute_actions( $i->{ $k } );
        }
    } elsif( ref $i eq 'ARRAY' ) {
        execute_actions( $_ ) for @$i;
    }
}

my $top = shift @ARGV;
if( ! @ARGV ) {
    push @ARGV, $top;
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
        say "$status $url";
    }

    # Skip non-HTML content...

    my $links = scrape( $body, [ { name => 'next', query => '//a[img[@id="picture"]]/@href', munge => ['absolute'], },
                                 { name => 'image', query => '//img[@id="picture"]/@src', munge => ['absolute'],},
                                ], {
        url => "" . $page->{req}->req->url,
    });

    for my $url ($links->{image}->@*) {

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
        # resume?

        #say "Download $url -> $filename";

        $crawler->submit_download({info => $info, GET => "$url",
        #headers => {
        #    Referer => $page->{info}->{url},
        #}
        } => $filename);
    }
    for my $url ($links->{next}->@*) {
        #my $u = URI->new( $url );

        next unless $url =~ /^http/i;
        next unless $url =~ /^\Q$top\E/i;

        #if( $url =~ /\.mpe?g/ ) {
        #    # do a HEAD instead?!
        #    next;
        #}

        my $u = $url;
        my $info = {
            url => $u,
            from => $page->{info}->{url},
        };
        $crawler->submit_request({info => $info, GET => "$url"});
    }

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
