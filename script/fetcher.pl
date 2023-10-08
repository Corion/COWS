use 5.020;
use COWS::FetchQueue;
use feature 'signatures';
no warnings 'experimental::signatures';

use URI;
#use lib '../Term-Output-List/lib';
use Term::Output::List;

use Getopt::Long;
use URI;
use YAML 'LoadFile';
#use Filesys::Notify::Simple;
#use File::Spec;
#use JSON;
use Text::Table;

use IO::Socket::UNIX;

GetOptions(
    'config|c=s'        => \my $config_file,
    'interactive|i'     => \my $interactive,
    'output-type|t=s'   => \my $output_type,
    'output-file|o=s'   => \my $output_file,
    'scrape-item|s=s'   => \my $scrape_item,
    'debug|d'           => \my $debug,
    'verbose'           => \my $verbose,
    'download-directory=s' => \my $target_directory,
    'socket-name=s'     => \my $sockname,
    'submission-timeout=s' => \my $submission_timeout,
    'domain-socket=s'   => \my $domain_socket,
    'tcp-socket=s'      => \my $tcp_socket,
);

my $config;

# How long we wait for items to be added after finishing the current items
$submission_timeout //= 3;
my $domain_dir     = $ENV{XDG_RUNTIME_DIR}
               //  $ENV{TEMP}
               // '/tmp';
$domain_socket_name //= $domain_dir
                      . "/fetcher-"
                      . ($ENV{LOGNAME} // $ENV{USER})
                      . '.sock'
                     ;

# create domain socket for submitting more things
my $domain_socket = IO::Socket::UNIX->new(
    Type => SOCK_STREAM(),
    Local => $domain_socket_name,
    Listen => 1,
);

sub add_url_listen( $socket ) {
    my $add_urls = Mojo::IOLoop::Stream->new($socket);

    my $buffer;
    $add_urls->on( read => sub( $stream, $bytes ) {
        $buffer .= $bytes;
        while( $buffer =~ s/\A(.*?)\r?\n// ) {
            handle_input( $1 );
        }
    });
    $add_urls->start;
    return $add_urls;
}

my @listeners;
push @listeners, add_url_listen( $domain_socket );
# create tcp socket for submitting more things
# create named pipe on Windows
# Create watcher on socket/pipe for submitting new URLs

sub handle_add_url( $line ) {
    if( $line =~ /\A\{/ ) {
        # JSON command
    } else {
        # line with a single URL in it
    }
}

binmode STDOUT, ':encoding(utf8)';

$target_directory //= '.';

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
    #my $config = LoadFile( $config_file );
    $config = {};
    return $config;
}

sub create_fetcher( $config, $cache=undef ) {
    my $crawler = COWS::FetchQueue->new(
        #base    => $config->{base},
        cache => $cache,
        debug => $debug,
    );

    $crawler->on('progress' => sub($c, $r, $res) {
        return unless my $len = $res->headers->content_length;

        #use Data::Dumper;
        #msg( Dumper $res );

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
        binmode STDOUT, ':encoding(utf8)';
        local $/;
        $content = <$fh>;
    };

    if( $content ne $new_content ) {
        if( open my $fh, '>', $filename ) {
            binmode STDOUT, ':encoding(utf8)';
            print $fh $new_content;
        } else {
            warn "Couldn't (re)write '$filename': $!";
        };
    };
}

my @known_extensions = (qw(
    gif
    jpg
    jpeg
    json
    pdf
    png
    gz
    zip
    7z
    bz2
));
my $re_known_extensions = join "|", @known_extensions;

sub guess_download_filename( $url ) {
    my $filename;
    if( $url =~ m!\b([^/?=]+\.($re_known_extensions))\b! ) {
        $filename = $1;
    };
    return $filename
}

sub handle_download( $crawler, $page, $url, $filename=undef ) {
    # launch a download
    my $info = {
        url => $url,
        from => $page->{info}->{url},
    };
    $filename //= guess_download_filename( $url );
    if( ! $filename ) {
        msg("Couldn't get filename for '$url', skipped");
        return;
    };
    #next if -e $filename;
    # resume downloads?

    my $target = File::Spec->catfile( $target_directory, $filename );

    $crawler->submit_download({info => $info, method => 'GET', url => "$url",
        headers => {
            Referer => $page->{info}->{url},
            # cookies?
        }
    } => $target);
}

sub scrape_pages($config, @items) {
    my $crawler = create_fetcher( $config );

    my @rows;
    for my $url (@items) {
        handle_download( $crawler, undef, $url, );
    }

    my @res;
    while( my ($page) = $crawler->next_page ) {

        # A download has finished one way or the other
        # rename it on success?!
    }
    # Well, not output, clear, but OK :D
    output_scoreboard();
}

sub do_scrape_items ( @items ) {
    my $config = load_config( $config_file );
    scrape_pages( $config => @items );
}

sub on_new_request( $line ) {
    $line =~ s/\s+\z//;
    scrape_pages( $config => $line );
}

do_scrape_items( @ARGV );
