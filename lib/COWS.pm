package COWS 0.01;

use 5.020;
use Carp 'croak';
use feature 'signatures';
no warnings 'experimental::signatures';
use Exporter 'import';

use XML::LibXML;
use HTML::Selector::XPath 'selector_to_xpath';
use List::Util 'reduce';

our @EXPORT_OK = ('scrape', 'scrape_xml');

=head1 NAME

COWS - Corion's Own Web Scraper

=head1 SYNOPSIS

XXX This needs restructuring. Each item should be a hashref.

    [
        {
            name => 'my_post',
            parts => [
                {foo},
                {bar},
                {baz}
            ],
        },
    ],

=head2 Structured items

We want

  items => [
      {
          content => '...',
          children => [
              { content => '...', children => [], },
              { content => '...', children => [], },
              { content => '...', children => [], },
          ],
      },
      { content => '...', children => [], },
  ]

What kind of config gets us there (recursive stuff nonwithstanding)?

Why do we want to have a hashref if we discard the name?!
Maybe we want something like C<children>, but how to specify multiple
connected sets of collections?!
Something like

    [
        {
            name => '???', # ignored
            single => 1,
            query => './p', # ...
            fields => [ # "children" ?!
                {
                    name    => 'content'
                    query   => './text()',
                    single  => 1,
                },
                {
                    name    => 'children',
                    query   => './p',
                    # how do we specify the recursion?!
                    # I guess one level deeper...
                    fields  => [ $_[ this ] ],
                },
            ],
        },
    ]

results in

    {
        ...
    }


    use COWS 'scrape';

    my $html = '...';
    my $rules = [
        { query => 'a@href',
          name  => 'links',
          munge => ['absolute'],
        },
    ];

    my %mungers = (
        # callbacks
        absolute => sub( $text, $node, $info ) {
            use URI;
            return URI->new_abs( $text, $info->{url} );
        },
    );

    my $data = scrape($html, $rules, {
        mungers => \%mungers,
        url => 'https://example.com'
    });

=cut

=for thinking

  div:       # unknown key/key which looks like a query, means query
    anonymous: 1 # instead of creating { div => items => [] } create { items => [] }
    items:   # how do we specify that these all get merged?! Maybe all arrays get merged?!
      - name: price
        query: div.gh_price
        index: 1
        force_single: 1
        munge: extract_price
      - name: merchant
        query: a@data-merchant-name
        index: 1
        force_single: 1
      - name: url
        query: a@href
        index: 1
        force_single: 1
        munge: absolute
  more_items:
    - name: other_price
      query: div.gh_price_2
      index: 1
      force_single: 1
  title: /head/title # second query?!

  # This would return
  {
    items => [ {}, {}, ... ],
    title => '...',
    more_items: [ ... ]
  }

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
    #use Data::Dumper; warn Dumper @$mungers;
    if( $mungers ) {
        my @l = ($val, @$mungers);
        return reduce { $b ? $b->($a, $node, $options) : $a } @l;
    } else {
        return $val
    }
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

sub scrape_xml_single_query(%options) {
    # Always returns an arrayref of arrayrefs
    my $options        = $options{ options };
    my $debug          = $options{ debug };
    my $node           = $options{ node };
    my $name           = $options{ name };
    my $query          = $options{ query };
    my $attribute      = $options{ attribute };
    my $context        = $options{ context };
    my $force_index    = $options{ force_index };
    my $force_single   = $options{ force_single };
    my $want_node_body = $options{ want_node_body };
    my $mungers        = $options{ mungers };

    my @res;

    if( $debug) {
        my $str = $node->toString;
        $str =~ s!\s+! !msg; # compress the string slightly
        if( length $str > 80 ) {
            substr( $str, 77 ) = '...';
        }
        say "$name [ $query ] $str"
    }

    # Make query relative to our context
    if( $query =~ m!^//! ) {
        $query = ".$query";
    }

    my $items = $node->findnodes( $query );

    my @found = $items->get_nodelist;
    if( $debug ) {
        say sprintf "Found %d nodes for $query", scalar @found;
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
        next unless $item;
        my $val = maybe_attr( $item, $attribute );
        if( $want_node_body ) {
            $val = $item->toString;
            # Strip the tag itself
            $val =~ s!^<[^>]+>!!;
            $val =~ s!</[^>]+>\z!!ms;
        }

        push @res,
            [ $item, scalar _apply_mungers( $val => $mungers, $item, $options ) ];
    }

    return \@res
}

sub scrape_xml_query($node, $rule, $options={}, $context={} ) {
    # if single==1 , return a hashref, otherwise an arrayref
    # can/do we want to return a plain string? type="list,object,string" ?
    my @res;

    # Can we maybe do this check before we walk the tree/start scraping?!
    our @keywords = (qw(single fields html index query name munge debug discard));
    my %_rule = %{ $rule };
    delete @_rule{ @keywords };
    croak "Unknown keyword(s) " . join ",", keys %_rule
        if scalar %_rule;

    my $name = $rule->{name};

    my $force_index;
    my $force_single;
    my $want_node_body;
    my @mungers;
    my $query = $rule->{ query };
    $query = [$query] if ! ref $query;

    $force_index = $rule->{ index };
    $force_single = $rule->{ single };
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

    if( $force_single ) {
        croak "Multiple things found for $rule->{query}"
            unless @res == 1;
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
                if( exists $info{ $_ }) {
                    croak sprintf "Duplicate item for '%s' (%s)", $_, $node->nodePath;
                };
                $info{ $_ } = $val->{ $_ };
            }

        } else {

            $info{ $r->{name} } = $child_value;
        };
    }
    return \%info
}


sub scrape_xml($node, $rules, $options={}, $context={} ) {
    ref $rules eq 'ARRAY'
        or croak "Got $rules, expected ARRAY";

    local $context->{path} = [ @{ $context->{path} // [] }];
    my $res = merge_xml_rules( $node, $rules, $options, $context );
    return $res;
}

sub scrape($html, $rules, $options = {} ) {
    $html =~ s!\A\s+!!sm;
    my $dom = XML::LibXML->load_html( string => $html, recover => 2 );
    return scrape_xml( $dom->documentElement, $rules, $options )
}

1;
