#!perl
use 5.020;
use Test2::V0;

use feature 'signatures';
no warnings 'experimental::signatures';

use XML::LibXML;
use Term::ReadKey;

use lib '../Term-Output-List/lib';
use Term::Output::List;

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
<div>more text</div>
<div><a href="https://example.com/4">fourth link</a> in text</div>
<div><div>nested</div></div>
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

my $printer = Term::Output::List->new();

sub node_vis( $node ) {
    my $vis = $node->textContent;
    $vis =~ s!\s+! !msg;
    if( length $vis > 10 ) { $vis = substr( $vis, 0, 7 ) . "..." };
    return sprintf "<%s> (%s)", $node->nodeName, $vis;
}

sub surrounding_nodes( $node, $strategy ) {
    my @res;
    my $curr = $node;
    for ( 1..10 ) {
        $curr = $strategy->($curr, $node);
        push @res, $curr
            if $curr;
    }

    @res
}

sub display_location( $context, $location, $curr_step, $action ) {
    # We also want the current path, and the location within the path

    my $path = $context->{path};
    my $pos = $context->{step};

    use Carp 'croak';
    croak "No position"
        unless defined $pos;

    my $vis = node_vis( $location );

    my $strategy = search_strategy( $curr_step );

    my @out;

    push @out, join " ", map { $_->{node} } @$path;

    my $idx = 0;
    push @out, join " ", map {
                             my $vis = ($idx++ == $pos) ? '^' : ' ';
                             '' . ($vis x length($_->{node}))
                         } @$path;

    my @next_nodes = surrounding_nodes( $location, $strategy );
    push @out, join " ", map { node_vis( $_ ) } @next_nodes;
    push @out, $action;

    $printer->output_list(@out);
}

sub display_step( $step ) {
    $printer->output_permanent( $step );
}

sub prompt() {
    ReadMode 2;
    <>;
    ReadMode 0;
}

sub search_strategy( $step ) {
    my %strategies = (
        '/'  => \&nextDirectChild,
        '//' => \&nextLinear,
    );

    my $strategy = $strategies{ $step->{ axis } };
    croak "Unknown traversal strategy '$step->{ axis }'" unless $strategy;

    return $strategy
}

sub nextLinear( $curr, $limit ) {
    return if ! $curr;
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
    return if ! $curr;
    $curr->nextNonBlankSibling
}

sub search_xpath(  $context, $node, $search_step, $last_step=undef, $limit = $node ) {
    local $| = 1;


    if( $search_step->{node} =~ /^\@/ ) {
        my $curr = $last_step // $node;
        display_step( "Checking attributes for $search_step->{node}" );
        if( my @r = node_match( $curr, $search_step )) {
            print "$search_step->{node} found\n";
            return ($r[0], undef) # no sense in continuing
        };
        display_location( $context, $curr, $search_step, '' );
        prompt();

    } else {

        my $strategy = search_strategy( $search_step );

        my $curr;
        if ( ! $last_step ) {
            #display_step( sprintf "Enumerating all children of %s for %s%s", $node->nodePath, $search_step->{axis}, $search_step->{node} );
            $curr = $node->firstChild;
        } else {
            $curr = $strategy->( $last_step, $limit );
            if( $curr ) {
                #display_step(
                #    sprintf "Enumerating next children of %s after %s for %s%s", $node->nodePath, $last_step->nodePath, $search_step->{axis}, $search_step->{node}
                #);
            }
        }
        if( ! $curr ) {
            display_step( "No child or next (non blank) sibling found" );
            return (undef, undef);
        }

        while( $curr ) {
            if( node_match( $curr, $search_step )) {
                display_location( $context, $curr, $search_step, sprintf "%s found", $curr->nodePath );
                display_location( $context, $curr, $search_step, '' );
                prompt();
                return ($curr, $curr)
            };
            display_location( $context, $curr, $search_step, '' );
            prompt();
            $curr = $strategy->( $curr, $limit );
        }
    }
}

sub trace_xpath( $query, $node ) {
    my @path = splitXPath( $query );

    my $curr = $node;
    # We want to collect all matches, not only the first, so we need to keep
    # track of the alternatives and chase them all
    # Maybe we still can do this by building our own stack and tracking it all
    # at the same time?!

    my @candidates; # stack of [path, $node] that we still want to try

    my $i = 0;

    display_step( "Evaluating candidates along the way" );

    my @found;
    # Now, go one step deeper, and collect all candidates there:
    @candidates = [$doc, -1, $doc];
    while( @candidates) {

        my ($curr, $i, $limit) = (shift @candidates)->@*;
        $i++;
        display_step(
            sprintf "Next candidate: <%s>, searching for .%s<%s>", $curr->nodeName, $path[$i]->{axis}, $path[$i]->{node}
        );

        my $justfound;
        my $cont;
        my $found;
        while( $curr ) {
            my $last = $curr;

            my $context = {
                path => \@path,
                step => $i,
            };

            ($found, $cont) = search_xpath( $context, $curr, $path[$i], $cont, $limit );
            if( $found ) {
                if( $i == $#path ) {
                    push @found, $found; # we found a terminal node
                    display_step(
                        sprintf "Found %s at %s, keeping", $found->nodeName, $found->nodePath
                    );
                    $justfound = 1;
                    undef $curr;

                    if( $cont ) {
                        push @candidates, [$cont, $i-1, $limit]; # collect alternatives for current step
                    }

                } else {
                    # We need to dig deeper
                    display_step(
                        sprintf "Found %s at %s as candidate for step %d (%s)", $found->nodeName, $found->nodePath, $i, $path[ $i ]->{node}
                    );

                    ## BFS is broken now
                    #if( $cont ) {
                    #    push @candidates, [$curr, $i, $limit]; # collect alternatives for current step
                    #}

                    # DFS
                    if( $cont ) {
                        push @candidates, [$cont, $i-1, $limit]; # collect alternatives for current step
                    }
                    $curr = $found;
                    undef $cont;

                    #display_step(
                    #    sprintf "Stepping from %s%s (%d) to %s%s", $path[ $i ]->{axis}, $path[ $i ]->{node}, $i, $path[ $i+1 ]->{axis}, $path[ $i+1 ]->{node};
                    #);
                    $i++;
                }
            } else {
                if( $justfound ) {
                    # no message here
                } else {
                    if( $last ) {
                        display_step(
                            sprintf "Failed, %s not found after %s", $path[$i]->{node}, $last->nodePath
                        );
                    } else {
                        display_step(
                            sprintf "Failed, %s not found", $path[$i]->{node}
                        );
                    }
                    if( @candidates ) {
                        display_step(
                            "... but we have more alternatives to try"
                        );
                    }
                }
                undef $curr;
                $justfound = 0;
            }
        };
    }

    if( @found ) {
        display_step( "Found " . $_->textContent ) for @found
    }
    return @found;
}

for my $query (
    '//a/@href',
    '//div/a/@href',
    '//div',
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
