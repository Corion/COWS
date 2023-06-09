#!perl
use 5.020;
use Test2::V0;

use COWS 'scrape';

my $html = <<'HTML';
<html>
<head>
    <title>Forum thread</title>
</head>
<body>
<nav>
<link rel="next" href="3.html">
<link rel="previous" href="1.html">
</nav>
<p><a href="release-3.zip">Release number 3</a></p>
<p><a href="release-2.zip">Release number 2</a></p>
<p><a href="release-1.zip">Release number 1</a></p>
</body>
</html>
HTML

my $flat = [
    { name => 'links',
      query => ['//link[@rel="next"]','//link[@rel="previous"]'],
      fields => [
                {
                    name => 'url',
                    query => './@href',
                    tag => 'action:follow("url")',
                    munge => 'url',
                    single => 1,
                },
                {
                    name => 'direction',
                    query => './@rel',
                    single => 1,
                }
        ],
    },
    { name => 'releases',
      query => '//p[a]',
      fields => [
            {
                name => 'link',
                query => 'a@href',
                tag => ['action:download("link")','output=console'],
                munge => 'url',
                single => 1,
            },
            {
                name => 'description',
                query => '//a[@href]',
                single => 1,
            }
      ],
    }

];

my $res = scrape( $html, $flat, { url => 'https://example.com/' } );

is $res, {
    links => [
        { url => 'https://example.com/3.html', direction => 'next', action => ['follow("url")'] },
        { url => 'https://example.com/1.html', direction => 'previous', action => ['follow("url")'] },
    ],
    releases => [
        { link => 'https://example.com/release-3.zip', description => 'Release number 3', action => ['download("link")'], output => 'console' },
        { link => 'https://example.com/release-2.zip', description => 'Release number 2', action => ['download("link")'], output => 'console' },
        { link => 'https://example.com/release-1.zip', description => 'Release number 1', action => ['download("link")'], output => 'console' },
    ],
}, "We found the relevant entries", $res;

$flat = [
    {
        name => 'url',
        query => 'link@href',
        tag => 'action:follow("url")',
        munge => 'url',
    },
    {
        name => 'link',
        query => 'a@href',
        tag => ['action:download("link")', 'output=console',],
        munge => 'url',
    },
];

$res = scrape( $html, $flat, { url => 'https://example.com/' } );

is $res, {
    action => ['follow("url")', 'download("link")'],
    link => ['https://example.com/release-3.zip','https://example.com/release-2.zip','https://example.com/release-1.zip'],
    url => ['https://example.com/3.html', 'https://example.com/1.html' ],
    output => 'console',
}, "Mixed action/arrays also work as expected", $res;

done_testing();
