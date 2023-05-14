package COWS::UserAgent 0.01;
use 5.020;
use feature 'signatures';

use Moo 2;
no warnings 'experimental::signatures';

use URI;
use COWS 'scrape';
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
  );
  my $url = $scraper->make_url( $item );
  my $html = $cache{ $url } // $scraper->fetch( "$url" );

  my $real_data = $scraper->parse({
      items => {
          query => "article.message"
          anonymous => 1,

          columns => [
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
              query =>  'div.message-content > div.message-userContent > article'
              html =>  1, # fetch whole node body
              single =>  1,
              munge =>  'compress_whitespace',
            },
          ],

  }, $html, { url => $url });

=cut

has 'ua' => (
    is => 'lazy',
    default => sub {
        Mojo::UserAgent->new(
            max_redirects => 2,
        );
    }
);

has 'base' => (
    is => 'ro',
);

has 'config' => (
    is => 'ro',
);

has 'mungers' => (
    is => 'ro',
);

sub make_url( $self, $id ) {
    my $base = $self->base;
    if( $base =~ /%/ ) {
        $base = sprintf $base, $id
    }
    return $base
}

sub fetch( $self, $url ) {
    my $res = $self->ua->get( $url )->result;
    croak "HTTP Error Code " . $res->code unless $res->code =~ /^2..$/;
    return $res->body
}

sub fetch_item( $self, $id) {
    return $self->fetch( $self->make_url($id));
}

sub parse( $self, $rules, $id_or_html, $options ) {
    my $html = $id_or_html;
    if( $id_or_html !~ /^</ ) {
        $html = $self->fetch_item( $id_or_html );
    };
    return scrape( $html, $rules,
        { debug => $options->{debug},
          mungers => $options->{mungers} // $self->mungers,
          url => $options->{url}
        });
}

1;
