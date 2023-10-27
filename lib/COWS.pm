package COWS 0.01;

use 5.020;
use utf8;
use Carp 'croak';
use feature 'signatures';
no warnings 'experimental::signatures';
use Exporter 'import';

use File::Spec;
use XML::LibXML;
use HTML::Selector::XPath 'selector_to_xpath';
use List::Util 'reduce';

use COWS::Mungers;

our @EXPORT_OK = ('scrape', 'scrape_xml');

=head1 NAME

COWS - Corion's Own Web Scraper

=head1 SYNOPSIS

  use 5.020;
  use COWS 'scrape';

  my $html = '...';
  my $rules = [
      {
          name => 'link',
          query => 'a@href',
          munge => ['absolute'],
      },
  ];
  my $res = scrape( $html, $rules, { url => 'https://example.com/' } );

  say "url: $_" for $res->{link}->@*;

=cut

sub maybe_attr( $item, $attribute ) {
    my $val;
    if( $attribute ) {
        $val = $item->value;
    } else {
        $val = $item->textContent;
    };
    return $val;
}

sub _apply_mungers( $val, $mungers, $node, $options ) {
    $mungers //= [];
    my @l = ($val, @$mungers);
    return reduce { $b ? $b->($a, $node, $options) : $a } @l;
}

sub _fix_up_selector( $q ) {
    my $attribute;
    if( $q && $q !~ m!/! && $q !~ m!::!) {
        # We have something like a CSS selector
        if( $q =~ m!^(.*)\@([\w-]+)\z! ) {
            # we have a query for an attribute, and selector_to_xpath doesn't like attributes-with-dashes :(
            $q = $1;
            $attribute = $2;
        };
        $q = selector_to_xpath($q);
    }
    # Queries always are relative to the current node
    # except if they are absolute to the root element. Not ideal.
    if($q =~ m!^//! ) {
        $q = ".$q";
    }

    # If we stripped off the attribute before, tack it on again
    if( defined $attribute ) {
        if( $q ) {
            $q .= sprintf '/@%s', $attribute;
        } else { $q = './@'.$attribute }
    }
    return ($q, $attribute);
}

sub _term_cols() {
    state $have_tput = system('tput cols 2>&1 >'.File::Spec->devnull);
    if( 0==$have_tput ) {
        return 0+`tput cols`;
    } else {
        return 80
    }
}

sub node_vis($node, $max_len=undef) {

    $max_len //= _term_cols;

    my $str = $node->toString;
    $str =~ s!\s+! !msg; # compress the string slightly
    if( length $str > $max_len-1 ) {
        substr( $str, $max_len-3 ) = '...';
    }
    return $str
}

sub scrape_xml_single_query(%options) {
    # Always returns an arrayref of arrayrefs
    my $options        = $options{ options };
    my $debug          = $options{ debug };
    my $node           = $options{ node };
    my $name           = $options{ name }; # only needed for debugging/interactive
    my $query          = $options{ query };
    my $attribute      = $options{ attribute };
    my $context        = $options{ context };
    my $force_index    = $options{ force_index };
    my $force_single   = $options{ force_single };
    my $want_node_body = $options{ want_node_body };
    my $mungers        = $options{ mungers } // \%COWS::Mungers::mungers;

    my @res;

    if( $debug) {
        my $str = node_vis($node);
        say "$name [ $query ] $str"
    }

    # Make query relative to our context
    if( $query =~ m!^//! ) {
        $query = ".$query";
    }

    my $items;
    if( $query =~ /^\./ ) {
        $items = $node->findnodes( $query );
    } else {

        $items = $node->ownerDocument->documentElement->findnodes( $query );
    }

    my @found = $items->get_nodelist;
    if( $debug ) {
        say sprintf "Found %d nodes for $query", scalar @found;
        for( @found ) {
            say node_vis($_);
        };
    }

    if( defined $force_index) {
        @found = $found[ $force_index-1 ];
    } elsif( $force_single ) {
        if( @found > 1 ) {
            # XXX want a context_as_string() sub
            say "** $_" for @found;
            croak "More than one element found for " . join " -> ", $context->{path}->@*;
        }
    }

    for my $item (@found) {
        next unless defined $item;
        my $val = maybe_attr( $item, $attribute );
        #say "Processing $item => $val" if $debug;
        if( $want_node_body ) {
            $val = $item->toString;
            # Strip the tag itself
            $val =~ s!^<[^>]+>!!;
            $val =~ s!</[^>]+>\z!!ms;
        }

        my $scraped = scalar _apply_mungers( $val => $mungers, $item, $options );
        #say "==> $scraped";
        push @res,
            [ $item, $scraped ];
    }

    return \@res
}

sub scrape_xml_query($node, $rule, $options={}, $context={} ) {
    # if single==1 , return a hashref, otherwise an arrayref
    # can/do we want to return a plain string? type="list,object,string" ?
    my @res;

    # Can we maybe do this check before we walk the tree/start scraping?!
    our @keywords = (qw(single fields html index query name munge debug discard tag meta));
    my %_rule = %{ $rule };
    delete @_rule{ @keywords };
    croak "Unknown keyword(s) in rule '$rule->{name}': " . join ",", keys %_rule
        if scalar %_rule;
    if( exists $rule->{name} ) {
        exists $rule->{query} or exists $rule->{meta}
            or croak "Need an XPath query for rule '$rule->{name}'";
    }

    my $name = $rule->{name};
    my $force_index;
    my $force_single;
    my $want_node_body;
    my @mungers;

    my $query = $rule->{ query };
    $query = [$query] if ! ref $query;

    $force_index = $rule->{ index };
    $force_single = $rule->{ single } // $rule->{meta};
    $want_node_body = delete $rule->{ html };

    if( exists $rule->{ munge }) {
        my $m = $rule->{ munge };

        if( ! ref $m or ref $m ne 'ARRAY') {
            $m = [$m];
        }

        @mungers = map {
            my $m = $_;
            my $munger;
            if( ref $m ) { # code ref
                $munger = $m;
            } elsif( $options->{mungers}->{ $m }) { # name
                $munger = $options->{mungers}->{ $m };
            } else {
                croak "Got an unknown munger name '$m'";
            }
            $munger
        } @$m;
    }

    my $debug = $options->{debug} || $rule->{ debug };

    push $context->{path}->@*, $name;

    if( my $key = $rule->{meta} ) {
        push @res, $options->{ $key };

    } else {

        for my $q (@$query) {

            # Fix up the query
            my( $query, $attribute ) = _fix_up_selector($q);

            my @found = scrape_xml_single_query(
                context        => $context,
                options        => $options,
                debug          => $debug,
                node           => $node,
                name           => $name,
                query          => $query,
                attribute      => $attribute,
                rules          => $rule,
                mungers        => \@mungers,
                force_index    => $force_index,
                force_single   => $force_single,
                want_node_body => $want_node_body,
            );

            # Is this unwrapping across results OK here?!
            for my $i (map { @$_ } @found ) {
                my ($node, $val ) = @$i;
                if( my $child_rules = $rule->{fields}) {
                    # collect the fields for each element too
                    my $info = merge_xml_rules( $node, $child_rules, $options, $context );
                    push @res, $info;

                } else {
                    # Use the values instead of the nodes
                    push @res, $val;
                }

            }
        }
    }

    if( $force_index ) {
        @res = $res[$force_index -1];
    }

    if( $force_single ) {
        croak "Multiple things found for @$query"
            unless @res <= 1;
        return $res[0]

    } else {
        return \@res
    }
}

sub merge_xml_rules( $node, $rules, $options, $context ) {
    my %info;
    for my $r (@$rules) {
        if( exists $info{ $r->{name} }) {
            croak sprintf "Duplicate item for '%s' (%s)", $r->{name}, $node->nodePath;
        };

        my $child_value = scrape_xml_query( $node, $r, $options, $context );
        if( $r->{discard} ) {
            # unwrap this intermediate result
            my $val;
            if( ref $child_value eq 'ARRAY' ) {

                if( @$child_value > 1 ) {
                    use Data::Dumper; warn Dumper $child_value;
                    die "More than one result for $r->{name}";
                    exit;
                };

                $val = $child_value->[0];
            } else {
                $val = $child_value;
            }

            for (keys %$val) {
                # Can/should we merge identical key+value ?
                if( exists $info{ $_ }) {
                    croak sprintf "Duplicate item for '%s' (%s)", $_, $node->nodePath;
                };
                $info{ $_ } = $val->{ $_ };
            }

        } else {
            #say "$r->{name} => $child_value";

            $info{ $r->{name} } = $child_value;
        };

        if( my $tags = $r->{tag} ) {
            $tags = [$tags] unless ref $tags;
            for my $t ( $tags->@* ) {
                my ($k,$mode,$v) = ($t =~ /^([^=:]+)([=:])(.*)$/)
                    or croak "Unknown tag format '$t'";

                # What about single/repeating tags?
                # Would these be categories then?! Do we have a third word?

                if( $mode eq ':' ) {
                    $info{$k} //= [];
                    if( ! grep { $_ eq $v } $info{$k}->@* ) {
                        push $info{$k}->@*, $v;
                    }
                } elsif( $mode eq '=' ) {
                    $info{$k} //= $v;

                } else {
                    croak "Unknown tag mode '$mode'";
                }
            }
        }
    }
    return \%info
}


sub scrape_xml($node, $rules, $options={}, $context={} ) {
    ref $rules eq 'ARRAY'
        or croak "Got $rules, expected ARRAY";

    local $context->{path} = [ @{ $context->{path} // [] }];
    $options->{ mungers } //= { %COWS::Mungers::mungers };
    my $res = merge_xml_rules( $node, $rules, $options, $context );
    return $res;
}

=head2 C<< scrape >>

  scrape( $html, $rules, $options );

=cut

sub scrape($html, $rules, $options = {} ) {
    my $encoding = $options->{encoding} // 'UTF-8'; # best guess
    $html =~ s!\A\s+!!sm;
    #my $dom = XML::LibXML->load_html( string => $html, recover => 2 );
    my $parser = XML::LibXML->new();
    my $dom = $parser->parse_html_string( $html, { recover => 2, encoding => $encoding });
    return scrape_xml( $dom->documentElement, $rules, $options )
}

1;

=head1 QUERY SYNTAX

For each query, a hashref with the following keys is accepted

=over 4

=item C<name>

The name of this query. This will be used as a key in the resulting
hashref.

=item C<query>

The CSS selector or XPath query to search for.

=item C<fields>

Queries that should be matched below this node. The results will
get merged into a hashref. Duplicate names are not allowed (duh).

  fields => [
      { name => 'foo', ... },
      { name => 'bar', ... },
      { name => 'baz', ... },
  ]

results in

  { foo => ..., bar => ..., baz => ... }

=item C<debug>

Output progress while stepping through this query. This is convenient
for finding why a specific query doesn't result in what you think it
should.

=item C<single>

Expect only a single item, result will be the value of the query. If
the query has a C<fields> field, it will be a hashref of the fields.

If this key is missing, the result will always be an arrayref.

=item C<index>

Use the n-th node as result. The result will always be a hashref
or scalar value. This could be done in XPath but sometimes it's easier
to do it here.

=item C<discard>

Do not use this intermediate value but replace it by the arrayref of
its C<fields> value.

=item C<html>

Include the value of this node as an HTML string.

=item C<munge>

Apply the functions in the listed order to the value.

=item C<tag>

  tag => foo=bar
  tag => baz:bat

Add the key/value to the resulting hash. If the separator is C<=> , the result
will be a plain scalar:

  foo => 'bar',

If the separator is C<:>, there can
be multiple tags and they are collected in an arrayref:

    baz => [ 'bat' ],

=back
