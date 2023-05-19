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
<span id="post1">
<p>Hello there</p>
  <span id="reply1.1">
  <p>Welcome!</p>
  </span>
  <span id="reply1.2">
  <p>Welcome 2!</p>
  </span>
</span>
<span id="post2">
<p>Hi</p>
</span>
</body>
</html>
HTML

my @res = scrape( $html, {
    query => 'span',
    anonymous => 1,
    stuff => [
            content => {
                name => 'content',
                query => 'p/text()',
                single => 1,
            },
            id => {
                query => './@id',
                name => 'id',
                single => 1,
            }
        # How will we go about recursively collecting our replies?!
    ],
}, { base => 'https://example.com/' } );

is $res[0], [
    { id => 'post1',    content => 'Hello there', },
    { id => 'reply1.1', content => 'Welcome!', },
    { id => 'reply1.2', content => 'Welcome 2!', },
    { id => 'post2',    content => 'Hi', },
], "We found the relevant posts", $res[0];

done_testing();
