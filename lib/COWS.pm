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

    use COWS 'scrape';

    my $html = '...';
    my $rules = {
        items => { query => 'a@href',
                   name => 'links',
                   munge => ['absolute'],
                 },
    };

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
        munge: extract_price()
      - name: merchant
        query: a@data-merchant-name
        index: 1
        force_single: 1
      - name: url
        query: a@href
        index: 1
        force_single: 1
        absolute: 1
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

sub scrape_xml_list($node, $rules, $options={}, $context={} ) {
    ref $rules eq 'ARRAY'
        or die "Internal error: Got $rules, expected ARRAY";

    my @subitems;
    my %item;
    for my $r (@$rules) {
        push @subitems, scrape_xml( $node, $r, $options, $context );
        # Can we output "item '$r->{name}' not found in debug mode here?!
    };

    # Now, mush up the @subitems into a hash again
    for my $i (@subitems) {
        next unless $i;

        if( $i and ref $i ne 'HASH' ) {
            use Data::Dumper;
            die 'Not a hash: ' . Dumper \@subitems;
        };
        my ($name, $value) = %{$i};
        if( exists $item{ $name }) {
            use Data::Dumper;
            warn Dumper \%item;
            warn Dumper $i;
            croak "Duplicate item '$name' found :/";
        }
        $item{ $name } = $value;
    }

    return \%item;
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

sub scrape_xml_single_query(%options) {
    my $options        = $options{ options };
    my $debug          = $options{ debug };
    my $node           = $options{ node };
    my $name           = $options{ name };
    my $anonymous      = $options{ anonymous };
    my $query          = $options{ query };
    my $attribute      = $options{ attribute };
    my $context        = $options{ context };
    my $rules          = $options{ rules };
    my $mungers        = $options{ mungers };
    my $force_index    = $options{ force_index };
    my $force_single   = $options{ force_single };
    my $want_node_body = $options{ want_node_body };

    ref $rules eq 'HASH'
        or die "Internal error: Got $rules, expected HASH";

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

    my @subitems = values %$rules;

    my $items = $node->findnodes( $query );

    my @found = $items->get_nodelist;
    if( $debug ) {
        say sprintf "Found %d nodes for $query", scalar @found;
    }

    if( defined $force_index) {
        @found = $found[ $force_index-1 ];
    } elsif( $force_single ) {
        if( @found > 1 ) {
            #use Data::Dumper;
            #warn Dumper \@found;
            say "** $_" for @found;
            croak "More than one element found for " . join " -> ", $context->{path}->@*;
        }
    }

    for my $item (@found) {
        next unless $item;
        if( @subitems) {
            for my $rule (@subitems) {
                # Here we don't apply the munger?!
                if( ref $rule ) {
                    my @res2 = scrape_xml( $item, $rule, $options, $context );
                    if( $force_single ) {
                        if( @res2 > 1 ) {
                            use Data::Dumper;
                            warn Dumper \@res2;
                            croak "More than one element found for " . join " -> ", $context->{path}->@*;

                        } else {
                            my $item = $res2[0];
                            my $val = maybe_attr( $item, $attribute );

                            if( $want_node_body ) {
                                $val = $item->toString;
                            }

                            push @res, { $name => $val };
                        }
                    };
                    if( $anonymous ) {
                        # we expect an array of (single-element) arrays,
                        # merge those:
                        push @res, @res2;
                    } else {
                        push @res, { $name => [ scrape_xml( $item, $rule, $options, $context )] };
                    }
                } else {
                    my $val = maybe_attr( $item, $attribute );
                    if( $want_node_body ) {
                        $val = $item->toString;
                    }
                    push @res, { $name => _apply_mungers( $val => $mungers, $item, $options ) };

                }
            }
        } else {
            my $val = maybe_attr( $item, $attribute );
            if( $want_node_body ) {
                $val = $item->toString;
                # Strip the tag itself
                $val =~ s!^<[^>]+>!!;
                $val =~ s!</[^>]+>\z!!ms;
            }

            if( $anonymous ) {
                push @res, _apply_mungers( $val => $mungers, $item, $options );
            } else {
                if( ! $name ) {
                    push @res, _apply_mungers( $val => $mungers, $item, $options );
                } else {
                    push @res, { $name => _apply_mungers( $val => $mungers, $item, $options )};
                }
            }
        }
    }

    return @res
}

sub _fix_up_selector( $q ) {
    my $attribute;
    if( $q && $q !~ m!/! ) {
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
        $q .= sprintf '/@%s', $attribute;
    }
    return ($q, $attribute);
}

sub scrape_xml($node, $rules, $options={}, $context={} ) {
    my @res;

    # Maybe have a first pass that creates a canonical data structure?!

    local $context->{path} = [ @{ $context->{path} // [] }];

    if( ref $rules eq 'HASH' ) {
        my %_rules = %$rules;
        my $anonymous;

        my $force_index;
        my $force_single;
        my $want_node_body;
        my @mungers;

        if( exists $_rules{ index }) {
            $force_index = delete $_rules{ index };
        }

        if( exists $_rules{ anonymous }) {
            $anonymous = delete $_rules{ anonymous };
        }

        if( exists $_rules{ single }) {
            $force_single = delete $_rules{ single };
        }

        if( exists $_rules{ html }) {
            $want_node_body = delete $_rules{ html };
        }

        if( exists $_rules{ munge }) {
            my $m = delete $_rules{ munge };

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

        my $debug = $options->{debug} || delete $_rules{ debug };

        my $single_query;
        #warn Dumper \%_rules;
        if( exists $_rules{ query } ) {
            $single_query = delete $_rules{ query };

            if( ! ref $single_query) {
                $single_query = [$single_query];
            }
        }

        my @subitems;

        if( exists $_rules{ name } ) {
            @subitems = delete $_rules{ name };

        #} elsif( scalar keys %_rules == 1 ) {
        #    # Plain name, that means anonymous (?!)
        #    ($name) = keys (%_rules);
        #    $anonymous = 1;

        } else {
            # Multiple keys, or even a single key:
            @subitems = (sort keys %_rules);
            #$name = $rules;
            # Anonymous results are handled one level below this (?!)
        };

        if( defined $single_query and @subitems > 1 ) {
            croak "Can't have a query ($single_query) and multiple things (@subitems) at the same time";
        }

        # We have a weird double dispatch here.
        if( ! defined $single_query ) {
            # we have a list of @subitems that we want to collect:
            #warn "List of items: @subitems";
            my %res;
            for my $name (@subitems) {
                my $r = $_rules{ $name };
                #warn "Fetching $name (" . ref($r) . ")";

                # We always expect a scalar here?!
                $res{ $name } = scrape_xml($node, $r, $options, $context );
            };
            return \%res

        } else {
            # we have a name and a query (where do we have the name from?!)
            croak "Nothing to do at " . join " -> ", $context->{path}->@*
                if @subitems > 1;
            my $name = $subitems[0];

            push $context->{path}->@*, $name;

            for my $q (@$single_query) {

                # Fix up the query
                my( $query, $attribute ) = _fix_up_selector($q);

                push @res, scrape_xml_single_query(
                    context        => $context,
                    options        => $options,
                    debug          => $debug,
                    node           => $node,
                    name           => $name,
                    anonymous      => $anonymous,
                    subitems       => \@subitems,
                    query          => $query,
                    attribute      => $attribute,
                    rules          => \%_rules,
                    mungers        => \@mungers,
                    force_index    => $force_index,
                    force_single   => $force_single,
                    want_node_body => $want_node_body,
                );
            }
        }

        if( $debug) {
            warn "Found " . Dumper \@res;
        }

        if( $force_single ) {

            if( @res > 1 and not wantarray ) {
                warn ref $rules;
                use Data::Dumper;
                warn Dumper \@res;
                die "Called in scalar context for "  . join " -> ", $context->{path}->@*;
            }
            return $res[0]

        } else {
            return \@res
        }


    } elsif( ref $rules eq 'ARRAY' ) {
        return scrape_xml_list( $node, $rules, $options, $context );

    } else {
        my $items = $node->findnodes( ".//$rules");
        my $name = $rules;
        for my $item ($items->get_nodelist) {
            push @res, { $name => $item->textContent };
        }
    }

    return wantarray ? @res : $res[0]
}

sub scrape($html, $rules, $options = {} ) {
    $html =~ s!\A\s+!!sm;
    my $dom = XML::LibXML->load_html( string => $html, recover => 2 );
    return scrape_xml( $dom->documentElement, $rules, $options )
}

1;
