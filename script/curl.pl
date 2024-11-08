use 5.020;
use COWS::Crawler;
use experimental 'signatures';
use experimental 'try';
use PerlX::Maybe;

use URI;
use Term::Output::List;
use HTTP::Request::FromCurl;

use Getopt::Long ':config' => 'pass_through';
use Encode 'decode';
use URI;
use File::Spec;
use JobFunnel;
use JobFunnel::ProgressItem;

GetOptions(
    'h|help' => \my $help,
    'target-directory=s' => \my $target_directory,

    # Funnel options
    'domain-socket=s' => \my $domain_socket_name,
    'background'      => \my $dont_wait_for_completion,
    'grace-timeout=s' => \my $grace_timeout,
    'server'          => \my $keep_running,
);

# XXX do we want a sleep option to wait between requests?
#     between all requests?! what about requests from mungers?!
#     or should effective_url not be a munger but an action?!

$target_directory //= '.';

binmode STDOUT, ':encoding(utf8)';

# The progress output
my $printer = Term::Output::List->new(
    hook_warnings => 1,
);
# Also redirect program warnings to our handler

my $funnel = JobFunnel->new(
    maybe domain_socket_name  => $domain_socket_name,
          wait_for_completion => !$dont_wait_for_completion,
                      new_job => \&submit_download,
);
$funnel->on( update => sub { output_scoreboard() });
if( !$keep_running ) {
    $funnel->on('idle' => sub { Mojo::IOLoop->stop_gracefully });
};

my $ua = Mojo::UserAgent->new();

my @running;

sub submit_download( $request ) {
    my $method = $request->{method};
    my $url = $request->{url};
    my %headers = %{ $request->{headers} // {} };
    my $filename = $request->{target};
    msg("$method $url");

    my $progress = $request->{progress} // JobFunnel::ProgressItem->new(
        visual => $url,
        action => 'dl',
        total  => undef,
    );

    # See also LWP::UserAgent
    # If the file exists, add a cache-related header
    if ( -e $filename ) {
        my ($mtime) = ( stat($filename) )[9];
        if ($mtime) {
            $headers{ 'If-Modified-Since' } = HTTP::Date::time2str($mtime);
        }
    }

    my $req = $ua->build_tx( $method => "$url", \%headers, '' );
    $req->res->on( 'progress' => sub($res,@rest) {
        return unless my $len = $res->headers->content_length;
        $progress->total( $len ) if $len;
        $progress->progress($res->content->progress);
    });

    $req->res->on( 'finish' => sub($res,@rest) {
        # Only save if successful and not already there:
        if( $res->code == 206 ) {
            if( open my $fh, '>>:raw', $filename) {
                seek $fh, 0, 2; # Append
                print $fh $res->content->asset->slurp;

            } else {
                msg("Error: Can't append to '$filename': $!");
            };

        } elsif( $res->code =~ /^2\d\d/ ) {
            $res->save_to( $filename ) or warn "$!";
            # Update utime from the server Last-Changed header, if we know it
            if ( my $lm = $res->headers->last_modified ) {
                $lm = HTTP::Date::str2time( $lm );
                utime $lm, $lm, $filename
                    or warn "Cannot update modification time of '$filename': $!\n";
            }

        } elsif( $res->code == 304 ) {
            # unchanged
        } elsif( $res->code =~ /^3\d\d/ ) {
            # what do we do about 301 redirects?!
            msg(sprintf "Got %d status for $url", $res->code);

            my $redirect = { $request->%* };
            $redirect->{progress} = $progress;
            $redirect->{url} = $res->headers->header('Location');

            submit_download($redirect);

        } else {
            msg(sprintf "HTTP Error %d: %s", $res->code, $res->message);
        }
        $progress->finish();
    });

    push @running, $ua->start_p( $req );

    return $progress
}

sub status($item) {
    my $perc = $item->percent;
    $perc = defined $perc ? sprintf "% 3d%%", $perc : ' -- ';
    my $vis = $item->visual // '?';
    return sprintf "%s %s %s", $perc, $item->action, $vis;
}

sub output_scoreboard(@) {
    my @scoreboard;
    if( $funnel ) {
        @scoreboard = $funnel->jobs->@*;
    };
    $printer->output_list(
        map { status( $_ ) } @scoreboard
    );
}

sub msg($msg) {
    $printer->output_permanent($msg);
    output_scoreboard();
}

my @known_extensions = (qw(
    gif
    jpg
    jpeg
    json
    pdf
    png
    tar.gz
    html
));
my $re_known_extensions = join "|", @known_extensions;

sub handle_download( $req ) {
    my $url = $req->uri;

    my $filename = $req->output;

    if( !$filename) {
        if( $url =~ m!\b([^/?=]+\.($re_known_extensions))\b! ) {
            $filename = $1;
        } else {
            die "Couldn't guess filename from '$url'";
        }
    }

    my $target = File::Spec->catfile( $target_directory, $filename );
    if( -e $target ) {
        msg( "$target already exists, resuming" );
        $req->headers->{Range} = "bytes=" . -s( $filename ). "-";
    };

    if( ! -d $target_directory ) {
        mkpath $target_directory;
    };

    my $job = {
        filename => $filename,
        target   => $target,
        method   => $req->method,
        headers  => $req->headers,
        url      => $req->uri,
    };
    $funnel->add($job);
}

my @requests = HTTP::Request::FromCurl->new( argv => \@ARGV );
for my $r (@requests) {
    handle_download( $r );
}
Mojo::IOLoop->start unless Mojo::IOLoop->is_running;
