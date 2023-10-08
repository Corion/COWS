package COWS::FetchQueue 0.01;
use 5.020;
use feature 'signatures';
use Moo 2;
no warnings 'experimental::signatures';
with 'MooX::Role::EventEmitter';

use Scalar::Util 'weaken';
use Mojo::UserAgent;
use Mojo::IOLoop; # well, maybe move that to Net::Async or Future, later
use Mojo::Asset::File;
use URI;
use HTTP::Date;

=head1 NAME

COWS::Crawler - a page/fetch queue

=head1 SYNOPSIS

  my $queue = COWS::FetchQueue->new();
  $queue->submit_request({ method => 'GET', url => $url, info => { url => $url }} );
  while( my ($request) = $queue->next_request ) {
      my $body = $request->{res}->body;
      my $url = $request->{req}->req->url;
      my $status = $request->{res}->code;

      say "$url done";
  }
  $crawler->submit_request({info => $info, method => 'GET', url => "$_"})
      for @ARGV;

=cut

has 'ioloop' => (
    is => 'lazy',
    default => sub { Mojo::IOLoop->singleton },
);

# XXX how can we (also) allow for using WWW::Mechanize::Chrome here
#     instead of Mojo::UserAgent?!
#     also other UAs, provided we give them EventEmitters ?!
has 'ua' => (
    is => 'lazy',
    default => sub { Mojo::UserAgent->new },
);

has 'queue' => (
    is => 'ro',
    default => sub { [] },
);

has 'inflight' => (
    is => 'ro',
    default => sub { {} },
);

has 'seen' => (
    is => 'ro',
    default => sub { {} },
);

has 'cache' => (
    is => 'ro',
    # must be set in the constructor
    # XXX maybe later transfor cache => 1 into cache => {}
);

# Having a limiter with a set of categories would be interesting
# Number of scraping requests in flight
# Maybe we should revisit Future::Limiter , or rewrite it
has 'max_requests' => (
    is => 'ro',
    default => 4,
);

# No download speed limiting
# also downloads and normal requests compete, but do we care
# maybe we later want different names for queues?!
# we also have no per-host / per-IP limits

# We use this for populating the seen/cache thing
sub normalize_request( $self, $request ) {
    # We don't handle/"cache" POST
    return unless exists $request->{ 'GET' };
    # filter cookies? why?
    # also, we don't want hashes, but that's what we have currently
    # return $request->as_string

    my $res = URI->new( $request->{'GET'})->canonical;
    $res->fragment('');
    return $res
}

sub start_request($self, $r) {
    weaken (my $s = $self);

    # XXX move to Future?
    my $req = $r->{req};

    my $id = $self->normalize_request( { $req->req->method, $req->req->url } );
    my $cached;
    if( $id and my $c = $self->cache ) {
        $cached = $c->{ $id };
    }

    my $req_p_start;
    if( $cached ) {
        $req_p_start = Mojo::Promise->new->resolve( $cached );

    } else {
        $req_p_start = $self->ua->start_p( $req )->then(sub($tx) {
            if( my $c = $self->cache ) {
                #say "Caching $id (" . ref( $tx->result ) . ")";
                $c->{$id} = $tx->result;
            };
            return $tx->result;
        });
    }
    my $req_p = $req_p_start->then(sub($resp) {
        delete $s->inflight->{ $req };
        $r->{res} = $resp;
        $s->emit('complete' => $r );

    })->catch(sub($err,@rest) {
        delete $s->inflight->{ $req };
        $s->emit('error' => $r );
    });

    $self->inflight->{ $req } = $req_p;

    return $req
}

sub next_page_p( $self ) {
    my ($res, $error);
    my $p = Mojo::Promise->new;
    $self->once('complete' => sub($self,$request) {
        $p->resolve( $request );
    });
    $self->on('error' => sub($self,$request) {
        $p->reject($request);
    });

    # If we have not enough things in flight, start some more
    # Should this be another method, so we can refill also when we don'
    # pick up fetched pages quick enough?
    while( keys $self->inflight->%* < $self->max_requests
           and $self->queue->@*
    ) {
        my $r = shift $self->queue->@*;
        $self->start_request( $r );
    }

    return $p
}

# Waits until the next request has finished and returns that
sub next_page($self) {
    my $done;
    my $res_p = $self->next_page_p()->finally(sub {
        $done++
    });


    # If we have nothing in flight, we can't wait for anything
    if( keys $self->inflight->%* ) {
        # Now, run things until we get a reply done
        do {
            #print sprintf "%d requests, %d waiting\r", scalar keys $self->inflight->%*, scalar $self->queue->@*;
            $self->ioloop->one_tick;
        } until $done;

        # WTF? The promise has no getter to get at the result? Should I really
        # have to set up ->then / ->catch calls just to get at the results?!
        return $res_p->{results}->[0]
    } else {
        #say "No inflight requests";
        return
    }
}

# do we want push/unshift, to manage the expansion
sub submit_request( $self, $request ) {
    my ( $info ) = $request->{ info };
    my $method = $request->{method};
    my $url = $request->{url};
    my %headers = %{ $request->{headers} // {} };

    my $id = $self->normalize_request( $request );
    if( $id ) {
        if( $id and $self->seen->{$id}) {
            # we already fetched this one
            #say "Already know $id";
            return;
        }
        $self->seen->{$id} = 1;
        #say "New URL $id";
    }

    weaken (my $s = $self);
    my $req = $self->ua->build_tx( $method => $url, \%headers );
    my $queued = { req => $req, info => $info };
    push $self->queue->@*, $queued;

    $req->res->on( 'progress' => sub($res,@rest) {
        $s->emit('progress', $queued, $res);
    });
    $req->res->on( 'finish' => sub($res,@rest) {
        $s->emit('finish', $queued, $res);
    });

    return $queued
}

# do we want push/unshift, to manage the expansion
sub submit_download( $self, $request, $filename ) {
    my ( $info ) = $request->{ info };
    my $method = $request->{method};
    my $url = $request->{url};
    my %headers = %{ $request->{headers} // {} };

    my $id = $self->normalize_request( $request );
    if( $id ) {
        if( $id and $self->seen->{$id}) {
            # we already fetched this one
            #say "Already know $id";
            return;
        }
        $self->seen->{$id} = 1;
    }

    weaken (my $s = $self);

    my $tempname = "$filename.part";

    # See also LWP::UserAgent
    # If the file exists, add a cache-related header
    # also we would like to resume partial downloads ...
    my $storage;
    if ( -e $filename ) {
        my ($mtime) = ( stat($filename) )[9];
        if ($mtime) {
            $headers{ 'If-Modified-Since' } = HTTP::Date::time2str($mtime);
        }
        $storage = Mojo::Asset::File->new({ path => $filename });
    } elsif( -e $tempname ) {
        #
        say "File download resume is not yet implemented";
        $storage = Mojo::Asset::File->new({ path => $tempname });
    } else {
        open my $fh, '>', $tempname;
        $storage = Mojo::Asset::File->new({ path => $tempname });
    }

    my $req = $self->ua->build_tx( $method => $url, \%headers, '' );

    # Save the response body (if any) directly to a file
    # This is not great as in the case of an error
    $req->res->{body} = $storage;

    my $queued = { req => $req, info => $info };
    $req->res->on( 'progress' => sub($res,@rest) {
        $s->emit('progress', $queued, $res);
    });
    $req->res->on( 'finish' => sub($res,@rest) {
        # Only save if successful and not already there:
        if( $res->code =~ /^2\d\d/ ) {
            # move_to, not save_to ?!
            $res->save_to( $filename );
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
            warn sprintf "Got %d status for $url", $res->code;
        }
        $s->emit('finish', $queued, $res);
    });

    push $self->queue->@*, $queued;

    return $queued
}

1;
