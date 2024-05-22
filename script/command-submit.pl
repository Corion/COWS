#!perl

package COWS::ProgressItem 0.01;
use Moo 2;
with 'MooX::Role::ProgressItem';

1;

use 5.020;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::JSON 'encode_json', 'decode_json';
use feature 'signatures';
no warnings 'experimental::signatures';

use Term::Output::List;

use Getopt::Long;
GetOptions(
    'domain-socket=s' => \my $domain_socket_name,
    'background'      => \my $dont_wait_for_completion,
    'grace-timeout=s' => \my $grace_timeout,
);

# XXX fix, later
$dont_wait_for_completion //= 1;

my( $domain_dir)  = grep { defined $_ && -d $_ }
                        $ENV{XDG_RUNTIME_DIR},
                        $ENV{TEMP},
                        '/tmp',
                        ;
$domain_socket_name //= $domain_dir
                     . "/fetcher-"
                     . ($ENV{LOGNAME} // $ENV{USER})
                     . '.sock'
                    ;

# Upscale @ARGV into "real" commands:
my @items = @ARGV;

if( -e $domain_socket_name ) {
    # XXX remove later
    my %options = (
        dont_wait_for_completion => $dont_wait_for_completion,
        socket_name => $domain_socket_name,
    );
    if( client_submit(\%options, @items)) {
        exit
    }
}

sub client_submit( $options, @items ) {
    #say "Submitting as client";
    my $loop = Mojo::IOLoop->singleton;
    my $res = 1;

    my %outstanding; # unify with @scoreboard!
    my $count = 0;

    my $id = $loop->client( { path => $options->{socket_name} } => sub ($loop, $err, $stream, @rest) {
        if( $err ) {
            $res = 0;
            $loop->stop_gracefully;
            # we thought we were the client, but we are the server
            # return zero to the main process knows to continue
        };

        if( $options->{dont_wait_for_completion} ) {
            #say "Will quit immediately";
            $stream->on(drain => sub {
                #say "Shutting down";
                $loop->stop_gracefully if $loop;
            });

        } else {
            #say "Waiting for replies";
            my $s = $stream->with_roles('+LineBuffer');
            $s->on( read_line => sub( $stream, $line, $sep ) {
                #say "REPLY: $line";
                # U

                # Stop if no outstanding replies
            });
            $s->on( close => sub($stream) {
                # The other side closes if it is done with our stuff
                $loop->stop_gracefully if $loop;
            });
        };

        # submit some client id too!
        # do we really need the id? We can simply output whatever the server
        # sends us instead. What else would we do?!
        # We are done when the server closes the connection...
        for my $l (@items) {
            my $id = "$$\0" . $count++;
            if( ref $l ) {
                local $l->{id} = $id;
                $outstanding{ $id } = COWS::ProgressItem->new(
                    total => undef,
                    visual => $l->{url}, # ???
                );
            }
            my $line = ref $l ? json_encode( $l ) : $l;
            $stream->write("$line\n");
        };
    });

    $loop->start unless $loop->is_running;

    $res;
}

sub add_url_listener( @args ) {
    my $id = Mojo::IOLoop->server( { @args } => sub( $loop, $stream, $id ) {
        $stream->with_roles('+LineBuffer')->on(read_line => sub( $stream, $line, $sep) {
            my $res = handle_add_url($line);
            # Can we somehow keep track here or should that happen in the
            # real code?!
            # Do we even want? This means we create a full-blown non-persistent
            # job server, instead of a small add-on ...
            # how/where do we get a job id from?!
            if( defined $res ) {
                $stream->write_line( encode_json( $res ));
            }

            # Also, close the stream once all items are done?!
        });
        $stream->watch_lines;

    });

    return $id;
}

my $is_server;
END { unlink $domain_socket_name if $is_server };

# create domain socket for submitting more things
add_url_listener( path => $domain_socket_name );
$is_server = 1;
# optionally output the domain socket name?!
# create tcp socket for submitting more things
my $id = add_url_listener( address => 'localhost' );
# optionally write the TCP port to a file, as a shell statement (?!)
# or maybe write it to fd 3 ?
# create named pipe on Windows
# but we cannot asynchronously poll a named pipe/thread from within Mojolicious
# (or whatever) without creating a socketpair :-/

# The progress output
my $printer = Term::Output::List->new();
my @scoreboard;

sub status($item) {
    my $perc = $item->percent;
    $perc = defined $perc ? sprintf "% 3d%%", $perc : ' -- ';
    return sprintf "%s %s %s", $perc, $item->action, $item->visual;
}

sub output_scoreboard() {
    #my $debug = sprintf "%d requests, %d pending", scalar(keys %scoreboard), scalar $crawler->queue->@*;
    $printer->output_list(
        #$debug,
        map { status( $_ ) } @scoreboard
    );
    if( ! @scoreboard ) {
        Mojo::IOLoop->stop_gracefully;
    }
}

sub msg($msg) {
    $printer->output_permanent($msg);
    output_scoreboard();
}

sub handle_add_url( $line ) {
    if( $line =~ /\A\{/ ) {
        # JSON command
        #msg("JSON: $line");
    } else {
        # line with a single URL in it
        #msg("PLAIN: $line");
    }

    my $body = 0;
    my $size = rand(10)+4;

    my $item = COWS::ProgressItem->new(
        visual => $line,
        action => 'launched',
        total  => $size,
    );
    push @scoreboard, $item;
    $item->on( start => sub { output_scoreboard });
    $item->on( progress => sub { output_scoreboard });
    $item->on( finish => sub { output_scoreboard });

    #my $f = Future->new;
    $item->{_feed} = Mojo::IOLoop->recurring(
        1 => sub {
            $item->progress( $body++, 'process' );
            if( $body >= $size ) {
                @scoreboard = grep { $_ != $item } @scoreboard;
                $item->finish();
                delete $item->{_feed};
                output_scoreboard();
            }
        },
    );
    # return a Future / Mojo::Promise , just in case somebody wants to
    # keep track
    # Do we want that even? Wouldn't some event emitter or callback be
    # better?
    # A Future would mean we get the final completion information, but
    # we also want to assign/return some id and also emit intermediate results
    # the event emitter could emit stuff, and potentially have an accessor
    # like ->id() that returns the id for the client?!
    # But that puts a burden on the programmer-user of this code again
}

for my $item (@ARGV) {
    handle_add_url( $item );
}

# Actually, this should be $grace_timeout seconds after all items have been
# processed, or maybe $grace_timeout seconds after the program has started,
# or until all items have been processed, whichever is longer
#my $timeout = Mojo::IOLoop->timer( $grace_timeout => sub {
#    Mojo::IOLoop->stop_gracefully
#});

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

