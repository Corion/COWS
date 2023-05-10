#!perl
use 5.020;
use Mojolicious;


package Scraper::FromYaml 0.1;
use 5.020;
use feature 'signatures';

use Moo 2;
no warnings 'experimental::signatures';

use URI;
use lib '/home/corion/Projekte/Corion-Scraper/lib';
use Corion::Scraper 'scrape';
use Mojo::UserAgent;

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
    sprintf $self->base, $id
}

sub fetch_data( $self, $id) {
    my $res = $self->ua->get( $self->make_url($id))->result;
    die "Code " . $res->code unless $res->code =~ /^2..$/;
    $res->body
}

sub extract_price( $text ) {
    $text =~ s/.*?(\d+)[.,](\d\d).*/$1.$2/r
}

sub parse( $self, $rules, $id_or_html ) {
    my $html = $id_or_html;
    if( $id_or_html !~ /^</ ) {
        $html = $self->fetch_data( $id_or_html );
    };
    return scrape( $html, $rules, { debug => 1, mungers => $self->mungers });
}

use Getopt::Long;

# Read merchant whitelist from config?
use YAML 'LoadFile';

GetOptions(
    'config|c=s' => \my $config_file,
);

my $config = LoadFile( $config_file );
if( ! $config->{items} ) {
    die "$config_file: No 'items' section found";
}

my %handlers = (
    extract_price => \&extract_price,
);

my $scraper = Scraper::FromYaml->new(
    mungers => \%handlers,
    base => $config->{base},
);

my @rows;
for my $item (@ARGV) {
    my $data = $scraper->parse($config->{items}, $item);

    push @rows, map { $_->{item} = $item; $_ } @{$data};
}

my @columns;
if( ! $config->{columns}) {
    my %columns;
    for(@rows) {
        for my $k (keys %$_) {
            $columns{ $k } = 1;
        }
    }
    @columns = sort keys %columns;
} else {
    @columns = $config->{columns}->@*;
}

# Can we usefully output things as RSS ?!
use Text::Table;
my $res = Text::Table->new(@columns);
$res->load(map { [@{ $_ }{ @columns }] } @rows);
say $res;

