#!perl

package COWS::ProgressItem 0.01;
use Moo 2;
with 'MooX::Role::ProgressItem';

1;

# XXX rename from MooX to (maybe) COWS:: or something else
package MooX::JobFunnel 0.01;
use Moo 2;
use experimental 'signatures';
use File::Basename;

with 'MooX::Role::EventEmitter';

# emits
# update (to update the scoreboard)
# idle
# added (when a new item must be started)

has 'appname' => (
    is => 'ro',
    default => sub { basename($0) },
);

has 'fds' => (
    is => 'ro',
    default => sub { [] },
);

has 'wait_for_completion' => (
    is => 'ro',
    default => 1,
);

has 'domain_dir' => (
    is => 'ro',
    default => \&_build_domain_socket_dir_default,
);

has 'domain_socket_name' => (
    is => 'ro',
    default => \&_build_domain_socket_name,
);

has 'cleanup' => (
    is => 'rw',
);

has 'worker' => (
    is => 'lazy',
    default => \&_build_worker,
    handles => [qw[ jobs add ]],
);

# The callback to create a fresh ProgressItem
has 'new_job' => (
    is => 'ro',
    required => 1,
);

sub DEMOLISH( $self, $global ) {
    if( $self->cleanup ) {
        unlink $self->domain_socket_name;
    }
}

sub _build_domain_socket_dir_default($self, $env=\%ENV ) {
    # XXX for Windows, make this \\.\PIPE\
    my( $domain_dir)  = grep { defined $_ && -d $_ }
                            $env->{XDG_RUNTIME_DIR},
                            $env->{TEMP},
                            '/tmp',
                            ;
    return $domain_dir
}

sub _build_domain_socket_name( $self, $appname=$self->appname, $env=\%ENV ) {
    my $fn = sprintf '%s-%s.sock', $appname, ($env->{LOGNAME} // $env->{USER} // $env->{USERNAME});
    my $domain_socket_name = File::Spec->catfile( $self->domain_dir, $fn );
    return $domain_socket_name;
}

sub _build_worker( $self ) {
    my $worker;

    # Check if we have a local domain socket
    my $domain_socket_name = $self->_build_domain_socket_name( $self->appname );
    if( -e $domain_socket_name ) {
        # XXX remove later
        my %options = (
            wait_for_completion => !$self->wait_for_completion,
            socket_name => $domain_socket_name,
        );
        $worker = $self->_build_client();
    };

    if( ! $worker ) {
        $worker = $self->_build_server();
        my $l = $self->create_listener( { path => $domain_socket_name } );
        $self->cleanup(1);
        $l->on( 'line' => sub($l) { $worker->add( $l ); } );

        # Also create a socket, if wanted
        #$self->create_listener( address => $domain_socket_name, $worker );
    };

    $worker->on( update => sub { $self->emit('update') });

    return $worker
}

sub _build_server( $self ) {
    my $worker = MooX::JobFunnel::Worker::Server->new(
        new_job => $self->new_job,
    );

    # XXX configure forwarding the events, like add/update/done/idle

    return $worker
}

sub _build_client( $self ) {
    my $worker = MooX::JobFunnel::Worker::Client->new();

    # XXX configure forwarding the events, like add/update/done/idle

    return $worker
}

#package MooX::JobFunnel::Listener 0.01;
#use 5.020;
#use Moo 2;
#
=head1 NAME

MooX::JobFunnel::Listener - command channel

# emits
# line

=cut

sub create_listener( $self, $args ) {
    # Should emit the line instead of invoking a callback
    my $obj = COWS::ProgressItem->new();
    my $id = Mojo::IOLoop->server( $args => sub( $loop, $stream, $id ) {
        $stream->with_roles('+LineBuffer')->on(read_line => sub( $stream, $line, $sep) {
            # XXX decode the line to JSON before emitting it
            #$self->emit('line', $line );
            $obj->emit('line', $line );
            #my $res = handle_add_url($line);
            # Can we somehow keep track here or should that happen in the
            # real code?!
            # Do we even want? This means we create a full-blown non-persistent
            # job server, instead of a small add-on ...
            # how/where do we get a job id from?!
            # Instead, have the user call "us" somehow?!
            #if( defined $res ) {
            #    $stream->write_line( encode_json( $res ));
            #}

            # Also, close the stream once all items are done?!
        });
        $stream->watch_lines;

    });

    return $obj;
}

package MooX::JobFunnel::Worker::Server;
use 5.020;
use Moo 2;
use experimental 'signatures';

with 'MooX::Role::EventEmitter';

has 'jobs' => (
    is => 'ro',
    default => sub { [] },
);

# The callback
has 'new_job' => (
    is => 'ro',
    required => 1,
);

sub add( $self, $_job ) {
    my $progress = $self->new_job->( $_job );
    push $self->jobs->@*, $progress;
    #main::msg(sprintf "Launching %s", $progress->visual );
    $self->emit( 'added', $progress );
    $self->emit( 'update' );

    # This is the same for client and server
    $progress->on('progress' => sub { $self->emit( 'update' )});

    # This is the same for client and server
    $progress->on('finish' => sub {
        my $j = $self->jobs;
        $j->@* = grep { $_ != $progress } $j->@*;

        if( ! $j->@* ) {
            $self->emit('idle');
        }
    });

    # Fail?
    # Stalled?

    return $progress;
}

# How do we notify of
# idle
# done
# ???

package MooX::JobFunnel::Worker::Client;
use Moo 2;
use experimental 'signatures';

with 'MooX::Role::EventEmitter';

has 'jobs' => (
    is => 'ro',
    default => sub { [] },
);

has 'server' => (
    is => 'ro',
);

# Should we track some kind of id so we can also get remote progress?!
sub add( $self, $job ) {
    # Send job to server
    my $line = ref $job ? json_encode( $job ) : $job;
    $self->server->write("$line\n");

    # Create a progress item and return that here!
}

# How do we notify of
# idle
# done
# ???

package main;

use 5.020;
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::JSON 'encode_json', 'decode_json';
use experimental 'signatures';
use PerlX::Maybe;

use Term::Output::List;

use Getopt::Long;
GetOptions(
    'domain-socket=s' => \my $domain_socket_name,
    'background'      => \my $dont_wait_for_completion,
    'grace-timeout=s' => \my $grace_timeout,
    'server'          => \my $keep_running,
);

# XXX fix, later
$dont_wait_for_completion //= 1;

my $funnel = MooX::JobFunnel->new(
    maybe domain_socket_name  => $domain_socket_name,
          wait_for_completion => !$dont_wait_for_completion,
                      new_job => \&handle_add_url,
);
$domain_socket_name = $funnel->domain_socket_name;

# Upscale @ARGV into "real" commands:
my @items = @ARGV;

if( -e $domain_socket_name ) {
    # XXX remove later
    my %options = (
        wait_for_completion => !$dont_wait_for_completion,
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

# XXX this should go into ::FD::Domainsocket (or some such, or does a domain socket vanish if the process exits?)
my $is_server;
END { unlink $domain_socket_name if $is_server };

# create domain socket for submitting more things
#my $id = add_url_listener( path => $domain_socket_name );
#$is_server = 1;
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
my @scoreboard; # this (resp. the job list) would become a member of the handler class

sub status($item) {
    my $perc = $item->percent;
    $perc = defined $perc ? sprintf "% 3d%%", $perc : ' -- ';
    return sprintf "%s %s %s", $perc, $item->action, $item->visual;
}

sub output_scoreboard(@) {
    #my $debug = sprintf "%d requests, %d pending", scalar(keys %scoreboard), scalar $crawler->queue->@*;
    my @scoreboard = $funnel->jobs->@*;
    $printer->output_list(
        #$debug,
        map { status( $_ ) } @scoreboard
    );
    if( ! @scoreboard and ! $keep_running ) {
        Mojo::IOLoop->stop_gracefully;
    }
}

sub msg($msg) {
    $printer->output_permanent($msg);
    output_scoreboard();
}

# XXX convert from string to JSON objects before calling here!
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
    #$item->on( start => sub { output_scoreboard });
    #$item->on( progress => sub { output_scoreboard });
    #$item->on( finish => sub { output_scoreboard });

    #my $f = Future->new;
    $item->{_feed} = Mojo::IOLoop->recurring(
        1 => sub {
            $item->progress( $body++, 'process' );
            if( $body >= $size ) {
                #@scoreboard = grep { $_ != $item } @scoreboard;
                $item->finish();
                delete $item->{_feed};
                #output_scoreboard();
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
    return $item
}

$funnel->on('update' => \&output_scoreboard );
for my $item (@ARGV) {
    $funnel->add( $item );
    #handle_add_url( $item );
}

# Actually, this should be $grace_timeout seconds after all items have been
# processed, or maybe $grace_timeout seconds after the program has started,
# or until all items have been processed, whichever is longer
#my $timeout = Mojo::IOLoop->timer( $grace_timeout => sub {
#    Mojo::IOLoop->stop_gracefully
#});

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

