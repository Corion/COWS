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
use Mojo::JSON 'decode_json', 'encode_json';

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
        #warn sprintf 'Removing "%s"', $self->domain_socket_name;
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
            #wait_for_completion => !$self->wait_for_completion,
            path => $domain_socket_name,
        );
        #use Data::Dumper; warn "Trying local domain path " . Dumper \%options;
        $worker = $self->_build_client( \%options );
        #if( ! $worker ) {
        #    warn "No client, creating server";
        #};
    };

    # XXX create TCP listener?
    if( ! $worker ) {
        #warn "Building server";
        $worker = $self->_build_server();
        my $l = $self->create_listener( { path => $domain_socket_name } );
        $self->cleanup(1);
        $l->on( 'line' => sub($s, $stream, $line) {
            my( $payload, $id );
            if( ref $line ) {
                $payload = $line->{payload};
                $id = $line->{id};
                #main::msg("Got remote job $id");
            } else {
                $payload = $line;
                $id = '-';
            };
            my $item = $worker->add( $payload, "remote" );
            $item->id($id);
            my @keys = qw(id total action visual curr progress_state);
            $item->{$_} //= $line->{$_} for @keys;
            $item->on('progress' => sub {
                my @info = map { $_ => $item->$_ } @keys;
                my $progress = encode_json({ @info });
                #main::msg("SEND: $progress");
                $stream->write_line( $progress );
            });
            $item->on('finish' => sub {
                my @info = map { $_ => $item->$_ } @keys;
                my $progress = encode_json({ @info });
                #main::msg("FINI: $progress");
                $stream->write_line( $progress );
            });
        });

        # Also create a socket, if wanted
        #$self->create_listener( address => $domain_socket_name, $worker );
    };

    # XXX configure forwarding the events, like add/update/done/idle
    $worker->on( update => sub { $self->emit('update') });

    return $worker
}

sub _build_server( $self ) {
    my $worker = MooX::JobFunnel::Worker::Server->new(
        new_job => $self->new_job,
    );

    return $worker
}

sub _build_client( $self, $options ) {
    my $loop = Mojo::IOLoop->singleton;
    my $res = 1;
    #use Data::Dumper; warn "Client options: " . Dumper $options;
    #my $server = Future->new();
    my $server = Mojo::Promise->new();
    my $id = $loop->client( $options => sub ($loop, $err, $stream, @rest) {
        #use Data::Dumper; warn("->client CB for " . Dumper $options);
        if( $err ) {
            $res = 0;
            # we thought we were the client, but we are the server
            # fail the promise the worker builder knows to continue
            $server->reject();
            return
        };

        $server->resolve( $stream );

        # Do some protocol negotiation here
        # XXX Tell the server we want to receive progress information

        if( ! $self->wait_for_completion ) {
            #main::msg("Will quit immediately");
            $stream->on(drain => sub {
                #say "Shutting down";
                $loop->stop_gracefully if $loop;
            });

        } else {
            #main::msg("Waiting for replies");
            my $s = $stream->with_roles('+LineBuffer')->watch_lines;
            $s->on( read_line => sub( $stream, $line, $sep ) {
                #say "REPLY: $line";
                # U
                # XXX Find what item was updated from ->jobs()
                # emit a 'progress' on that item
                #main::msg("REPLY: $line");

                my $r = decode_json( $line );
                if( my $id = $r->{id} ) {
                    (my $item) = grep { $_->id eq $id } $self->jobs->@*;
                    if( ! $item ) {
                        main::msg("No item with id '$id' found?!");
                        main::msg(Dumper($r));
                    } else {
                        my @keys = qw(total action visual );
                        for( @keys ) {
                            $item->{$_} = $r->{$_} if exists $r->{$_};
                        };

                        if( $r->{progress_state} eq 'progressing' ) {
                            $item->progress( $r->{curr} );
                        } elsif( $r->{progress_state} eq 'finished' ) {
                            #main::msg("Item finished");
                            $item->finish()
                        } else {
                            main::msg("Unknown progress state '$r->{progress_state}'");
                        };
                    };
                };

                $self->emit('update');

                # Stop the loop if no outstanding replies (?)
            });
            $s->on( close => sub($stream) {
                # The other side closes if it is done with our stuff
                # Should we maybe simply emit 'idle' here instead?!
                # or "done" ?!
                $loop->stop_gracefully if $loop;
            });
        };
    });

    my $s;
    $server->then(
        sub { #warn "Have 'remote' stream";
              $s = $_[0]
            },
        sub { #warn "No 'remote' stream";
              undef $res
            }
    );
    #warn "Entering waitloop to await initalized server";
    $server->wait;

    if( $res ) {
        my $worker = MooX::JobFunnel::Worker::Client->new( server => $s );

        return $worker;
    } else {
        return
    }
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

=head2 C<< ->create_listener $args >>

  my $l = $f->create_listener( { path => '/path/to/socket' } );
  my $l = $f->create_listener( { address => 'localhost', port => 1042 } );
  $l->on('line' => sub($stream, $line) {
      say "< $line";
  });

Creates a listening socket and configures it for reading lines. Returns an
object that emits C<line> events.

Takes the same arguments as C<< Mojo::IOLoop->server >> .

=cut

sub create_listener( $self, $args ) {
    # This should be some better object than COWS::ProgressItem
    my $obj = COWS::ProgressItem->new();
    my $id = Mojo::IOLoop->server( $args => sub( $loop, $stream, $id ) {
        $stream->with_roles('+LineBuffer')->watch_lines->on(read_line => sub( $stream, $line, $sep) {
            if( $line =~ /\A\{/ ) {
                $line = decode_json( $line );
            }

            $obj->emit('line', $stream => $line );
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

sub add( $self, $job, $remote=undef ) {
    my( $id );
    state $local_id;
    # XXX this should maybe happen in the socket listener instead?!
    my $progress = $self->new_job->( $job );
    $progress->id( $id ) if $id;
    if( ! $remote ) {
        #  make up a (local) id
        $id = join "\0", $$, $local_id++;
    };
    push $self->jobs->@*, $progress;
    #main::msg(sprintf "Launching %s", $progress->visual );
    $self->emit( 'added', $progress );
    $self->emit( 'update' );

    # This is the same for client and server
    $progress->on('progress' => sub { $self->emit( 'update' ); });

    # This is the same for client and server
    $progress->on('finish' => sub($progress,@) {
        my $j = $self->jobs;
        $j->@* = grep { $_ != $progress } $j->@*;
        #main::msg(sprintf "Item %s done (%s)", $progress->id, $progress);
        #main::msg(sprintf "Jobs: " . join ", ", $j->@*);

        $self->emit('update');
        if( ! $j->@* ) {
            $self->emit('idle');
        };
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
use Mojo::JSON 'encode_json';

with 'MooX::Role::EventEmitter';

has 'jobs' => (
    is => 'ro',
    default => sub { [] },
);

has 'server' => (
    is => 'ro',
);

# Should we track some kind of id so we can also get remote progress?!
sub add( $self, $job, $remote=undef ) {
    # Send job to server
    state $client_id = 1;

    my $want_responses = undef;

    my $id = join( "\0", $$, $client_id++);

    my $line = ref $job ? encode_json( {
        id => $id, notify => $want_responses, payload => $job,
        # XXX make generic
        # we'll fetch the visual from the worker
        #visual => $job->{visual},
    }) : $job;
    my $s = $self->server;

    # Create a progress item and return that here!
    my $item = COWS::ProgressItem->new(
        total  => undef,
        visual => 'waiting for remote',
        id     => $id,
    );
    push $self->jobs->@*, $item;

    # This is the same between server and client
    $item->on('finish' => sub($progress,@) {
        my $j = $self->jobs;
        $j->@* = grep { $_ != $progress } $j->@*;

        $self->emit('update');
        if( ! $j->@* ) {
            $self->emit('idle');
        };
    });


    $s->write_line($line);

    $self->emit( 'added', $item );
    $self->emit( 'update' );

    return $item;
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
#$dont_wait_for_completion //= 1;

my $funnel = MooX::JobFunnel->new(
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
    # This should be the "idle" handler, not here
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
    my $body = 0;
    my $size = rand(10)+4;

    my $item = COWS::ProgressItem->new(
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

