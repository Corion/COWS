#!perl
use 5.020;
use Test2::V0;

use Corion::Scraper 'scrape';

my $html = <<'HTML';
<html>
<head>
    <title>Test title</title>
</head>
<body>
<div class="row">
    <div class="price">1.23</div>
    <div><a data-merchant="amazon" href="/out.cgi?ref=99">Clickme</a></div>
</div>
<div class="row">
    <div class="price">45.6</div>
    <div><a data-merchant="amazon" href="/out.cgi?ref=88">Clickme</a></div>
</div>
</body>
</html>
HTML

my @res = scrape( $html, {
    items => {
        query => 'div.row',
        anonymous => 1,
        #anonymous => 1, # this applies to 'columns' (?!)
        columns => [
            { name => 'price', query => 'div.price', single => 1, munge => sub { $_[0] =~ s/.*?(\d+)[.,](\d\d?)\b.*/$1.$2/r } },
            { name => 'merchant', query => 'a@data-merchant', single => 1 },
            { name => 'url', query => 'a@href', absolute => 1, single => 1 },
        ],
    },
    title => {
        query => '/html/head/title',
        single => 1,
    },
}, { base => 'https://example.com/' } );

is $res[0], {
    title => 'Test title',
    items => [
    { merchant => 'amazon', url => '/out.cgi?ref=99', price => '1.23' },
    { merchant => 'amazon', url => '/out.cgi?ref=88', price => '45.6' },
    ],
}, "We found the relevant items", $res[0];

done_testing();
