package COWS::Mungers 0.01 {
use 5.020;
use feature 'signatures';
no warnings 'experimental::signatures';

use Exporter 'import';
use URI;
use lib '../App-moveyear/lib';
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
    $text =~ s!\x{200e}! !msg;
    $text =~ s!\s+! !msg;
    $text =~ s!^\s+!!;
    $text =~ s!\s+$!!;
    return $text
}

sub extract_date( $text, $node, $info ) {
    my $dt = guess_ymd($text);
    return sprintf '%d-%02d-%02d', $dt->{year}, $dt->{month}, $dt->{day};
}

sub effective_url( $text, $node, $info ) {
    # where do we get $ua from?!
    # Do we want a "context" hash where we store more of that stuff?!
    # also, do we fail if we have no UA (due to offline action) or
    # do we simply return the text as-is?!
    my $ua;
    $ua->head( $text )->then(sub($response) {
        if( my $loc = $response->{header}->{location}) {
            return effective_url( $loc, $node, $info )
        } else {
            return url($text, $node, $info)
        }
    })
}

our %mungers = (
    extract_price       => \&extract_price,
    compress_whitespace => \&compress_whitespace,
    url                 => \&url,
    date                => \&extract_date,
    # effective_url     => \&effective_url, # does a HEAD on URLs to find all the redirects
);

}
