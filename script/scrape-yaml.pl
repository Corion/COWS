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
use COWS 'scrape';
use Mojo::UserAgent;
use Carp 'croak';

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

sub fetch_data( $self, $id) {
    my $res = $self->ua->get( $self->make_url($id))->result;
    croak "Code " . $res->code unless $res->code =~ /^2..$/;
    return $res->body
}

sub extract_price( $text ) {
    $text =~ s/.*?(\d+)[.,](\d\d).*/$1.$2/r
}

sub compress_whitespace( $text ) {
    $text =~ s!\s+! !msg;
    $text =~ s!^\s+!!;
    $text =~ s!\s+$!!;
    return $text
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
use Filesys::Notify::Simple;
use File::Spec;

GetOptions(
    'config|c=s'    => \my $config_file,
    'interactive|i' => \my $interactive,
);

sub load_config( $config_file ) {
    my $config = LoadFile( $config_file );
    if( ! $config->{items} ) {
        die "$config_file: No 'items' section found";
    }
    return $config;
}

my %handlers = (
    extract_price => \&extract_price,
    compress_whitespace => \&compress_whitespace,
);

sub create_scraper( $config ) {
    my $scraper = Scraper::FromYaml->new(
        mungers => \%handlers,
        base => $config->{base},
    );
}

my %cache;
sub scrape_pages($config, @items) {
    my $scraper = create_scraper( $config );

    my @rows;
    for my $item (@items) {
        my $data = $cache{ $item } // $scraper->parse($config->{items}, $item);

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
}

sub do_scrape_items ( @items ) {
    my $config = load_config( $config_file );
    scrape_pages( $config => @items );
}

do_scrape_items( @ARGV );
warn $interactive ? 'interactive mode' : 'batch mode';
if( $interactive ) {
    $config_file = File::Spec->rel2abs( $config_file );
    my $watcher = Filesys::Notify::Simple->new( [$config_file] );
    $watcher->wait(sub(@ev) {
        for( @ev ) {
            # re-filter, since we maybe got more than we wanted
            if( $_->{path} eq $config_file ) {
                do_scrape_items(@ARGV)
            #} else {
            #    warn "Ignoring change to $_->{path}";
            }
        };
    }) while 1;
}
