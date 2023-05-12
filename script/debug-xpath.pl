#!perl
use 5.020;
use Test2::V0;

use feature 'signatures';
no warnings 'experimental::signatures';

use XML::LibXML;

# XXX rename "axis" to something better, maybe "range" / "subtree" ?!
sub splitXPath( $query ) {
    my @nodes;

    # We assume a well-formed query
    # but do we really need/want that?! We could mush them together!
    #use Regexp::Debugger;
    while( $query =~ m!\G(?:
                            (?>(?<start>\.|))
                            (?>(?<axis>/+))
                            (?>(?<node>[^/]+)))
                    !xgc ) {
        my ($match) = keys %+;
        push @nodes, { %+ };
    }
    @nodes
}

my $doc = XML::LibXML->load_html(string => <<'HTML');
<html>
<head><title>HTML Test Page</title></head>
<body>
<a href="https://example.com/1">A link</a>
<a href="https://example.com/2">Another link</a>
<a name="Here">An anchor</a>
<div><a href="https://example.com/3">third link</a> in text</div>
</body>
</html>
HTML

sub node_match( $node, $step ) {
    my $query = $step->{ node };
    if( $query =~ /^\@/ ) {
        $query = "./$query";
    } else {
        $query = "self::" . $query;
    }

    #warn "At       " . $node->nodeName;
    #warn "Checking " . $query;

    my @found = $node->findnodes( $query );
    return $found[0]
}

sub display_location( $location, $curr_step ) {
    # We also want the current path, and the location within the path
    my $vis = $location->textContent;
    $vis =~ s!\s+! !msg;
    if( length $vis > 10 ) { $vis = substr( $vis, 0, 7 ) . "..." };
    say "<$curr_step->{node}> ?";
    print sprintf "\r<%s> (%s)", $location->nodeName, $vis;
}

sub nextLinear( $curr, $limit ) {
    if( $curr->hasChildNodes ) {
        #say "Descending";
        return $curr->firstChild
    } elsif( $curr->nextNonBlankSibling ) {
        #say "Same level";
        return $curr->nextNonBlankSibling
    } elsif( $curr->parentNode != $limit ) {
        #say "End of level, continuing upwards";
        while( $curr->parentNode && $curr->parentNode != $limit ) {
            $curr = $curr->parentNode;
            return if ! $curr;
            if( my $n = $curr->nextNonBlankSibling ) {
                return $n
            }
        }

        return
            if $curr == $limit;
    } else {
        return
    }
}

sub nextDirectChild( $curr, $limit ) {
    $curr->nextNonBlankSibling
}

sub search_xpath( $node, $search_step, $last_step=undef, $limit = $node ) {
    local $| = 1;

    if( $search_step->{node} =~ /^\@/ ) {
        my $curr = $last_step // $node;
        say "Checking attributes for $search_step->{node}";
        if( my @r = node_match( $curr, $search_step )) {
            print "$search_step->{node} found\n";
            return ($r[0], undef) # no sense in continuing
        };
        <>;

    } elsif( $search_step->{axis} eq '/' ) {
        say sprintf "Enumerating all children for %s%s", $search_step->{axis}, $search_step->{node};

        my $curr;
        if ( ! $last_step ) {
            say "Looking at first child";
            $curr = $node->firstChild;
        } else {
            $curr = nextDirectChild( $last_step, $limit )
        }
        if( ! $curr ) {
            say "No child or next (non blank) sibling found";
            return (undef, undef);
        }

        while( $curr ) {
            display_location( $curr, $search_step );

            if( node_match( $curr, $search_step )) {
                print " found\n";
                return ($curr, $curr)
            };
            <>;
            #my $d = $curr;
            #while( $d ) {
            #    #$d = $d->nextSibling;
            #    say $d->nodeName . " # " . $d->toString;
            #    $d = $d->nextNonBlankSibling;
            #}
            $curr = nextDirectChild( $curr, $limit );
        }
    } elsif( $search_step->{axis} eq '//' ) {

        say "Enumerating all successors";

        my $curr;
        if( ! $last_step ) {
            $curr = $node->firstChild
        } else {
            $curr = nextLinear( $last_step, $limit );
        }
        return (undef, undef) unless $curr;

        while( $curr ) {
            display_location( $curr, $search_step );

            if( node_match( $curr, $search_step )) {
                print " found\n";
                return ($curr, $curr)
            };
            <>;
            #my $d = $curr;
            #while( $d ) {
            #    #$d = $d->nextSibling;
            #    say $d->nodeName . " # " . $d->toString;
            #    $d = $d->nextNonBlankSibling;
            #}
            $curr = nextLinear($curr, $limit );
        }
    }
}

sub trace_xpath( $query, $node ) {
    my @path = splitXPath( $query );

    my $curr = $node;
    say $curr->nodeName;
    # We want to collect all matches, not only the first, so we need to keep
    # track of the alternatives and chase them all
    # Maybe we still can do this by building our own stack and tracking it all
    # at the same time?!

    my @candidates; # stack of [path, $node] that we still want to try

    my $i = 0;
    # Initialize our stack
    say "Initializing";
    do {
        $curr = search_xpath( $curr, $path[$i], undef, $node );
        if( $curr ) {
            push @candidates, [$curr, $i, $node]; # collect alternatives for current step
        }
    } until ! $curr;

    say "Evaluating candidates along the way";

    my @found;
    # Now, go one step deeper, and collect all candidates there:
    while( @candidates) {

        my ($curr, $i, $limit) = (shift @candidates)->@*;
        $i++;
        say sprintf "Next candidate: <%s>, searching for .%s<%s>", $curr->nodeName, $path[$i]->{axis}, $path[$i]->{node};

        my $justfound;
        my $cont;
        do {
            my $last = $curr;
            # $curr = search_xpath( $curr, $path[$i], undef, $limit );
            ($curr, $cont) = search_xpath( $curr, $path[$i], $cont, $limit );
            if( $curr ) {
                if( $i == $#path ) {
                    push @found, $curr; # we found a terminal node
                    say sprintf "Found %s at %s, keeping", $curr->nodeName, $curr->nodePath;
                    $justfound = 1;
                } else {
                    # We need to dig deeper
                    say sprintf "Found %s at %s as candidate for step %d", $curr->nodeName, $curr->nodePath, $i;

                    # BFS
                    #push @candidates, [$curr, $i, $limit]; # collect alternatives for current step

                    # DFS
                    unshift @candidates, [$curr, $i, $limit]; # collect alternatives for current step
                }
            } else {
                if( $justfound ) {
                    # no message here
                } else {
                    if( $last ) {
                        say sprintf "Failed, %s not found after %s", $path[$i]->{node}, $last->nodePath;
                    } else {
                        say sprintf "Failed, %s not found", $path[$i]->{node};
                    }
                    if( @candidates ) {
                        say "... but we have more alternatives to try";
                    }
                }
                $justfound = 0;
            }
        } until ! $cont;
    }

    if( @found ) {
        say "Found " . $_->textContent for @found
    }
    return @found;
}

for my $query (
    '//a/@href',
    '//div/a/@href',
    '/html/head/title[1]',
) {

    say "Searching for $query";
    #use Data::Dumper;
    #say Dumper $_ for splitXPath( $query );

    my @found = trace_xpath( $query, $doc );

    # Now check that our opinion of matches
    # is identical to XML::LibXML
    my @real = $doc->findnodes( $query );
    is( \@found, \@real, "$query matches identically with XML::LibXML" );
}

done_testing;
