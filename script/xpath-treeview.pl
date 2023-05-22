#!perl
use 5.020;
use Test2::V0;
use Carp 'croak';

use feature 'signatures';
no warnings 'experimental::signatures';

use XML::LibXML ':libxml';
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
<div id="link3" foo="bar" ><a href="https://example.com/3">third link</a> in text</div>
<div>more text</div>
<div><a href="https://example.com/4">fourth link</a> in text</div>
<div><div>nested</div></div>
</body>
</html>
HTML

my $printer = Term::Output::List->new();

sub node_vis( $node ) {
    my $vis = '';
    # Add text up to the first non-text child node
    my @ch = $node->childNodes;
    while( @ch and $ch[0]->nodeType == XML_TEXT_NODE ) {
        my $val = $ch[0]->nodeValue;
        if( $val =~ /\S/ ) {
            $vis .= $val;
        }
        shift @ch;
    }
    $vis =~ s!\s+! !msg;

    my $id;
    if( $node->hasAttributes ) {
        my $attr = $node->attributes->getNamedItem('id');
        if( $attr ) {
            $id = $attr->value;
        }
    };
    my $name = $id ? sprintf "%s#%s", $node->nodeName, $id : sprintf "%s", $node->nodeName;

    if( $node->nodeType == XML_TEXT_NODE ) {
        if( length $vis > 12 ) { $vis = substr( $vis, 0, 9 ) . "..." };
        return sprintf '"%s"', $vis;
    } else {
        if( length $vis > 10 ) { $vis = substr( $vis, 0, 7 ) . "..." };
        # Maybe have an option to show whitespace?!
        if( $vis =~ /\S/ ) {
            return sprintf "<%s> (%s)", $name, $vis;
        } else {
            return sprintf "<%s>", $name;
        }
    }
}

sub surrounding_nodes( $node, $strategy ) {
    my @res;
    my $curr = $node;
    for ( 1..5 ) {
        $curr = $strategy->($curr, $node);
        push @res, $curr
            if $curr;
    }

    @res
}

sub prompt() {
    ReadMode 2;
    <>;
    ReadMode 0;
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

sub prevLinear( $curr, $limit ) {
    return if ! $curr;
    my $prev = $curr->previousNonBlankSibling;
    if( $prev and $prev->hasChildNodes ) {
        return $prev->lastChild
    } elsif( $prev ) {
        return $prev
    } elsif( $curr->parentNode != $limit ) {
        #say "End of level, continuing upwards";
        $curr = $curr->parentNode;
    } else {
        return
    }
}

sub prevDirectChild( $curr, $limit ) {
    return if ! $curr;
    $curr->previousNonBlankSibling
}

=for thinking

breadCrumb / breadCrumb / ... /parent
  parent
  + prevSibling childNode1 ...
  + node
    + childNode1 grandChildNode1 ...
    + childNode2 grandChildNode2 ...
    ...
  + nextSibling childNode1 ...

=cut

sub prevSiblings( $node, $count ) {
    my $curr = $node->previousNonBlankSibling;
    my @res;
    while( $curr and $count--) {
        #say "$count pNBS: " . $curr;
        unshift @res, $curr;
        $curr = $curr->previousNonBlankSibling;
    };
    return @res;
}

sub nextSiblings( $node, $count ) {
    my $curr = $node->nextNonBlankSibling;
    my @res;
    while( $count-- and $curr and my $p = $curr->nextNonBlankSibling ) {
        push @res, $curr;
        $curr = $p;
    }
    return @res;
}

sub node_ancestors( $node ) {
    my @res;
    my $curr = $node;
    while( my $p = $curr->parentNode ) {
        unshift @res, $p;
        $curr = $p;
    }
    return @res
}

sub collapsed_node( $node, $options={} ) {
    my $prefix    = $options->{prefix} // '';
    my $max_width = $options->{max_width} // 80;

    # remove blank text nodes:
    my @children = grep { $_->nodeType != XML_TEXT_NODE or $_->nodeValue =~ /\S/ } $node->childNodes;
    # Remove first text node as it is included in node_vis()
    if( $children[0] and $children[0]->nodeType == XML_TEXT_NODE ) {
        shift @children;
    }

    my $res = $prefix . '+ ' . node_vis( $node );
    while( @children and length $res < $max_width ) {
        $res .= node_vis( shift @children );
    };
    if( length $res >= $max_width ) {
        substr($res, $max_width -3, 3) = '...';
    }

    return $res
}

# We should dynamically adjust the tree depth according to the terminal width
# Maybe we want *bold* for the current line, if the terminal permits?!
sub tree($node, $options={}) {
    $options->{max_depth} //= 1;
    $options->{max_width} //= 2;
    $options->{max_length} //= 5;
    $options->{term_width} //= 80;

    my $node_line_length = $options->{max_length}
                           - 1 # breadcrumb
                           - 1 # parent
                           ;

    my $prev_sibling_count = 2; # hardcoded
    my $next_sibling_count = 2; # hardcoded
    my $node_child_count = $options->{max_length} - $prev_sibling_count - $next_sibling_count;

    my $parent = $node->parentNode;
    my @breadcrumb = node_ancestors( $parent );
    my @prev_siblings = prevSiblings( $node, $prev_sibling_count );
    my @next_siblings = nextSiblings( $node, $next_sibling_count );
    my @child_nodes = grep { $_->nodeType != XML_TEXT_NODE or $_->nodeValue =~ /\S/ } $node->childNodes;

    # Remove first text node as it is included in node_vis()
    if( $child_nodes[0] and $child_nodes[0]->nodeType == XML_TEXT_NODE ) {
        shift @child_nodes;
    }

    if( @child_nodes > $node_child_count ) {
        splice @child_nodes, $node_child_count-1;
    };

    my @res;
    push @res, join "/", map { node_vis($_) } @breadcrumb;
    push @res, node_vis( $parent );
    push @res, map { collapsed_node( $_ ) } @prev_siblings;
    push @res, '> ' . node_vis( $node );
    push @res, map { collapsed_node( $_, { prefix => '  ' } ) } @child_nodes;
    push @res, map { collapsed_node( $_ ) } @next_siblings;

    return( @res )
}

for my $query (
    '//a[@href]',
    '//div/a[@href]',
    '//div',
    '/html/head/title[1]',
) {

    # Now check that our opinion of matches
    # is identical to XML::LibXML
    my @real = $doc->findnodes( $query );

    for my $node (@real) {
        $printer->output_list(tree($node));
        prompt();
    }
}
