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

my $flat = [{
    name => 'posts',
    query => 'span',
    fields => [
            {
                name => 'content',
                query => 'p/text()',
                single => 1,
            },
            {
                query => './@id',
                name => 'id',
                single => 1,
            }
        # How will we go about recursively collecting our replies?!
    ],
}];

my $res = scrape( $html, $flat, { base => 'https://example.com/' } );

is $res, { posts => [
    { id => 'post1',    content => 'Hello there', },
    { id => 'reply1.1', content => 'Welcome!', },
    { id => 'reply1.2', content => 'Welcome 2!', },
    { id => 'post2',    content => 'Hi', },
]}, "We found the relevant posts", $res;

my $post = {
    query => './span',
    name => 'posts',
    fields => [
            {
                name => 'content',
                query => 'p/text()',
                single => 1,
            },
            {
                query => './@id',
                name => 'id',
                single => 1,
            },
        # How will we go about recursively collecting our replies?!
    ],
};
# A post can have replies
push @{ $post->{fields} }, $post;

my $structured = [{
    query => '//body',
    name => 'toplevel',
    discard => 1,
    #single => 1,
    fields => [$post],
}];

$res = scrape( $html, $structured, { base => 'https://example.com/' } );
is $res, { posts => [
    { id => 'post1',    content => 'Hello there', posts => [
            { id => 'reply1.1', content => 'Welcome!', posts => [], },
            { id => 'reply1.2', content => 'Welcome 2!', posts => [], },
        ]},
    { id => 'post2',    content => 'Hi', posts => [] },
]}, "We found the relevant posts", $res;

done_testing();
