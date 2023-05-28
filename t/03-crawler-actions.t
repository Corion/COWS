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
                    tag => ['action:follow'],
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
                name => 'download',
                query => 'a@href',
                tag => 'action:download',
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
        { url => 'https://example.com/3.html', direction => 'next', action => 'follow' },
        { url => 'https://example.com/1.html', direction => 'previous', action => 'follow' },
    ],
    releases => [
        { download => 'https://example.com/release-3.zip', description => 'Release number 3', action => 'download' },
        { download => 'https://example.com/release-2.zip', description => 'Release number 2', action => 'download' },
        { download => 'https://example.com/release-1.zip', description => 'Release number 1', action => 'download' },
    ],
}, "We found the relevant entries", $res;

done_testing();
