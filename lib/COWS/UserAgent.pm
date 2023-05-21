package COWS::UserAgent 0.01;
use 5.020;
use feature 'signatures';

use Moo 2;
no warnings 'experimental::signatures';

use URI;
use COWS;
use Mojo::UserAgent;
use Carp 'croak';

=head1 NAME

COWS::UserAgent - useragent for scraping

=head1 SYNOPSIS

  my %cache;
  my $scraper = COWS::UserAgent->new(
      mungers => \%handlers,
      base => 'https://example.com/%s',
      debug => $debug,
      start_rule => 'items',
      config => [
        {
            query => "article.message",
            discard => 1,

            fields => [
              { name =>  'author',
                query =>  "./@data-author",
                single =>  1,
              },
              { name => 'avatar',
                query =>  'a.avatar@data-user-id',
                single =>  1,
              },
              { name =>  modified,
                query =>  'header ul.message-attribution-main time@datetime',
                single =>  1,
              },
              { name =>  content,
                query =>  'div.message-content > div.message-userContent > article',
                html =>  1, # fetch whole node body
                single =>  1,
                munge =>  'compress_whitespace',
              },
            ],
        },
      ],
  );

  my $data = $scraper->scrape({ url => $url });

=head1 ACCESSORS

=head2 C<< ->ua >>

The C<Mojo::UserAgent> to be used for fetching pages.

=cut

has 'ua' => (
    is => 'lazy',
    default => sub {
        Mojo::UserAgent->new(
            max_redirects => 2,
        );
    }
);

=head2 C<< ->base >>

The URL to be fetched from.

If the URL contains C<< %s >>, this will
be replaced by the item passed to C<< ->fetch_item >>.

=cut

has 'base' => (
    is => 'ro',
);

=head2 C<< ->config >>

The config as passed in.

=cut

has 'config' => (
    is => 'ro',
);

=head2 C<< ->mungers >>

A hashref of subroutine references that are used to post-process the items
as specified in the configuration.

The subroutine gets passed three parameters:

  sub munger($text, $node, $info) {
    ...
  }

The C<$info> hash is passed through from the call to C<< ->parse >>.

=cut

has 'mungers' => (
    is => 'ro',
);

=head1 METHODS

=cut

sub make_url( $self, $id ) {
    my $base = $self->base;
    if( $base =~ /%/ ) {
        $base = sprintf $base, $id
    }
    return $base
}

sub fetch( $self, $url ) {
    if( $url !~ /^http/i ) {
        croak "Internal error: malformed URL '$url'";
    };

    my $res = $self->ua->get( $url )->result;
    croak sprintf "HTTP Error Code %d: %s",
         $res->code, $res->message
        unless $res->code =~ /^2..$/;
    return $res->body
}

sub fetch_item( $self, $id) {
    return $self->fetch( $self->make_url($id));
}

=head2 C<< ->parse >>

  my $data = $ua->parse([
      {
          query => "article.message",
          discard => 1,

          fields => [
            { name =>  'author',
              query =>  "./@data-author",
              single =>  1,
            },
            { name =>  modified,
              query =>  'header ul.message-attribution-main time@datetime',
              single =>  1,
            },
          ]
      }
  ], 'searchitem', {
      url => $url, # info passed to
  });

=cut

sub parse( $self, $rules, $id_or_html, $options ) {
    my $html = $id_or_html;
    if( $id_or_html !~ /^\s*</ ) {
        $html = $self->fetch_item( $id_or_html );
    };
    return COWS::scrape( $html, $rules,
        { debug => $options->{debug},
          mungers => $options->{mungers} // $self->mungers,
          url => $options->{url}
        });
}

sub scrape( $self, %options ) {
    my $config = delete $options{ config };
    my $cache = delete $options{ cache } // {};
    my $start_rule = delete $options{ start_rule };
    my $info = delete $options{ info } // {};

    my $url = delete $options{ url };
    if( ! $url and ! exists $options{ item }) {
        croak "Need an item or url to scrape";
    }
    my $item = delete $options{ item };
    $url //= $self->make_url( $item );

    my $verbose = delete $options{ verbose };

    if( ! exists $config->{ $start_rule }) {
        croak "Start rule '$start_rule' does not exist in scraper config";
    }

    my $rows = [];

FETCH:
    say $url if( $verbose );
    my $html = $cache->{ $url } // $self->fetch( "$url" );

    # first check if we need to navigate on the page to the latest page:
    if( $config->{navigation} ) {
        $info->{ url } = $url;
        $info->{ item } = $item;
        my $data = $self->parse($config->{navigation}, $html, $info );
        if( $data->{refetch_page} ) {
            my $latest = URI->new_abs( $data->{refetch_page}, $url );
            if( $latest ne $url ) {
                $url = $latest;
                goto FETCH;
            }
        }
    }
    $info->{ url } = $url;
    $info->{ item } = $item;
    my $real_data = $self->parse($config->{$start_rule}, $html, $info);
    if( ref $real_data eq 'HASH' ) {
        push @$rows, $real_data;
    } else {
        push @$rows, map {
            $_->{item} //= $item;
            $_->{url}  //= $url;
            $_
        } @{$real_data};
    }

    return $rows
}

1;

=head1 CONFIGURATION

The configuration consists of several parts

=cut
