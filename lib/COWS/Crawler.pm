package COWS::Crawler 0.01 {
use 5.020;
use feature 'signatures';
use Moo 2;
no warnings 'experimental::signatures';
with 'MooX::Role::EventEmitter';

use Scalar::Util 'weaken';
use Mojo::UserAgent;
use Mojo::IOLoop; # well, maybe move that to Net::Async or Future, later
use URI;

=head1 NAME

COWS::Crawler - a page/fetch queue

=head1 SYNOPSIS

  my $crawler = COWS::Crawler->new();
  $crawler->submit_request({ GET => $url, info => { url => $url }} ) ;
  while( my ($page) = $crawler->next_page ) {
      my $body = $page->{res}->body;
      my $url = $page->{req}->req->url;
      my $status = $page->{res}->code;

      my $links = scrape( $body, [ { name => 'next', query => '//a[img[@id="picture"]]/@href', munge => ['absolute'], },
                                   { name => 'image', query => '//img[@id="picture"]/@src', munge => ['absolute'],},
                                  ], {
          mungers => {
              absolute => sub( $text, $node, $info ) {
                  my $res = URI->new_abs( $text, $info->{url} );
                  return $res;
              },
          },
          url => "" . $page->{req}->req->url,
      });
    for my $url ($links->{next}->@*) {
        next unless $url =~ /^http/i;
        next unless $url =~ /^\Q$top\E/i;
        $url->fragment('');

        my $u = $url;
        my $info = {
            url => $u,
            from => $page->{info}->{url},
        };
        $crawler->submit_request({info => $info, GET => "$url"});
    }
  }

=cut

has 'ioloop' => (
    is => 'lazy',
    default => sub { Mojo::IOLoop->singleton },
);

# XXX how can we (also) allow for using WWW::Mechanize::Chrome here
#     instead of Mojo::UserAgent?!
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

# Having a limiter with a set of categories would be interesting
# Number of scraping requests in flight
has 'max_requests' => (
    is => 'ro',
    default => 4,
);

# Number of downloads at the same time
has 'max_downloads' => (
    is => 'ro',
    default => 2,
);

# No download speed limiting

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
    my $req_p = $self->ua->start_p( $req )->then(sub($tx) {
        delete $s->inflight->{ $req };
        $r->{res} = $tx->result;
        $s->emit('complete' => $r );

    })->catch(sub($err,@rest) {
        delete $s->inflight->{ $req };
        $s->emit('error' => $r );
    });

    $self->inflight->{ $req } = $req_p;

    return $req
}

# Waits until the next request has finished and returns that
sub next_page($self) {
    my ($res, $error);
    $self->once('complete' => sub($self,$request) {
        $res = $request;
    });
    $self->on('error' => sub($self,$request) {
        $error = 1;
    });

    # If we have not enough things in flight, start some more
    while( keys $self->inflight->%* < $self->max_requests
           and $self->queue->@*
    ) {
        my $r = shift $self->queue->@*;
        $self->start_request( $r );
    }

    # If we have nothing in flight, we can't wait for anything
    local $| = 1;
    if( keys $self->inflight->%* ) {
        # Now, run things until we get a reply done
        do {
            print sprintf "%d requests, %d waiting\r", scalar keys $self->inflight->%*, scalar $self->queue->@*;
            $self->ioloop->one_tick;
        } until $res or $error;
        print "\n";

        return $res
    } else {
        say "No inflight requests";
        return
    }
}

# do we want push/unshift, to manage the expansion
sub submit_request( $self, $request ) {
    my ( $info ) = delete $request->{ info };

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
    my $req = $self->ua->build_tx( %$request );
    my $queued = { req => $req, info => $info };
    $req->res->on( 'progress' => sub($res,@rest) {
        $s->emit('progress', $queued, $res);
    });
    $req->res->on( 'finish' => sub($res,@rest) {
        $s->emit('finish', $queued, $res);
    });

    push $self->queue->@*, $queued;

    return $queued
}

# do we want push/unshift, to manage the expansion
sub submit_download( $self, $request, $filename ) {
    my ( $info ) = delete $request->{ info };

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
    my $req = $self->ua->build_tx( %$request );
    my $queued = { req => $req, info => $info };
    $req->res->on( 'progress' => sub($res,@rest) {
        $s->emit('progress', $queued, $res);
    });
    $req->res->on( 'finish' => sub($res,@rest) {
        $res->save_to( $filename );
        $s->emit('finish', $queued, $res);
    });

    push $self->queue->@*, $queued;
    say "$request->{GET} -> $filename";

    return $queued
}


}

1;
