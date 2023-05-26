package COWS::Mungers 0.01 {
use 5.020;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use URI;
use Date::Extract 'guess_ymd';

our @EXPORT_OK = qw(%mungers);

sub url( $text, $node, $info ) {
    my $res = URI->new_abs( $text, $info->{url} );
    return $res;
};

sub extract_price( $text, $node, $info ) {
    $text =~ s/.*?(\d+)[.,](\d\d).*/$1.$2/r
}

sub compress_whitespace( $text, $node, $info ) {
    $text =~ s!\s+! !msg;
    $text =~ s!^\s+!!;
    $text =~ s!\s+$!!;
    return $text
}

sub extract_date( $text, $node, $info ) {
    my $dt = guess_ymd($text);
    return sprintf '%d-%02d-%02d', $dt->{year}, $dt->{month}, $dt->{day};
}

my %mungers = (
    extract_price       => \&extract_price,
    compress_whitespace => \&compress_whitespace,
    url                 => \&url,
    date                => \&extract_date,
);

}
