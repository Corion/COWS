#!perl
package main;

use 5.020;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::JSON 'encode_json', 'decode_json';
use experimental 'signatures';
use PerlX::Maybe;

use Term::Output::List;
use JobFunnel;

use Getopt::Long;
GetOptions(
    'domain-socket=s' => \my $domain_socket_name,
    'background'      => \my $dont_wait_for_completion,
    'grace-timeout=s' => \my $grace_timeout,
    'server'          => \my $keep_running,
);

# XXX fix, later
#$dont_wait_for_completion //= 1;

my $funnel = JobFunnel->new(
    maybe domain_socket_name  => $domain_socket_name,
          wait_for_completion => !$dont_wait_for_completion,
                      new_job => \&handle_add_url,
);

# Upscale @ARGV into "real" commands:
my @items = @ARGV;

# optionally output the domain socket name?!
# create tcp socket for submitting more things
#$id //= add_url_listener( address => 'localhost' );
# optionally write the TCP port to a file, as a shell statement (?!)
# or maybe write it to fd 3 ?
# create named pipe on Windows
# but we cannot asynchronously poll a named pipe/thread from within Mojolicious
# (or whatever) without creating a socketpair :-/

# The progress output
my $printer = Term::Output::List->new();

sub status($item) {
    my $perc = $item->percent;
    $perc = defined $perc ? sprintf "% 3d%%", $perc : ' -- ';
    my $vis = $item->visual // '?';
    return sprintf "%s %s %s", $perc, $item->action, $vis;
}

sub output_scoreboard(@) {
    #my $debug = sprintf "%d requests, %d pending", scalar(keys %scoreboard), scalar $crawler->queue->@*;
    my @scoreboard;
    if( $funnel ) {
        @scoreboard = $funnel->jobs->@*;
    };
    $printer->output_list(
        #$debug,
        map { status( $_ ) } @scoreboard
    );
}

sub msg($msg) {
    $printer->output_permanent($msg);
    output_scoreboard();
}

# XXX convert from string to JSON objects before calling here!
sub handle_add_url( $line ) {
    my $body = 0;
    my $size = rand(10)+4;

    my $item = JobFunnel::ProgressItem->new(
        visual => $line->{visual},
        action => 'launched',
        total  => $size,
    );

    $item->{_feed} = Mojo::IOLoop->recurring(
        1 => sub {
            $item->progress( $body++, 'process' );
            if( $body >= $size ) {
                $item->finish();
                Mojo::IOLoop->remove($item->{_feed});
                delete $item->{_feed};
            }
        },
    );
    return $item
}

$funnel->on('update' => \&output_scoreboard );
if( !$keep_running ) {
    $funnel->on('idle' => sub { Mojo::IOLoop->stop_gracefully });
};
for my $item (@ARGV) {
    $funnel->add( { visual => $item } );
}

# Actually, this should be $grace_timeout seconds after all items have been
# processed, or maybe $grace_timeout seconds after the program has started,
# or until all items have been processed, whichever is longer
#my $timeout = Mojo::IOLoop->timer( $grace_timeout => sub {
#    Mojo::IOLoop->stop_gracefully
#});

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

