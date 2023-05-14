package COWS 0.01;

use 5.020;
use Carp 'croak';
use feature 'signatures';
no warnings 'experimental::signatures';
use Exporter 'import';

use XML::LibXML;
use HTML::Selector::XPath 'selector_to_xpath';

our @EXPORT_OK = ('scrape', 'scrape_xml');

=head1 NAME

COWS - Corion's Own Web Scraper

=head1 SYNOPSIS

    use COWS 'scrape';

    my $html = '...';
    my $rules = {
        ...
    };

    my %mungers = (
        ... # callbacks
    );

    my $data = scrape($html, $rules, { mungers => \%mungers });

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
        # What about multiple items returned here?!
        push @subitems, scrape_xml( $node, $r, $options, $context );
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

sub scrape_xml_single_query($node, $rules, $options={}, $context={} ) {
    ref $rules eq 'HASH'
        or die "Internal error: Got $rules, expected HASH";

}

sub scrape_xml($node, $rules, $options={}, $context={} ) {
    my @res;

    # Maybe have a first pass that creates a canonical data structure?!

    local $context->{path} = [ @{ $context->{path} // [] }];

    if( ref $rules eq 'HASH' ) {
        #my ($name,$query);
        #my @subitems;

        my %_rules = %$rules;
        my $anonymous;

        my $force_index;
        my $force_single;
        my $munger = sub( $text ) { $text };

        if( exists $_rules{ index }) {
            $force_index = delete $_rules{ index };
        }

        if( exists $_rules{ anonymous }) {
            $anonymous = delete $_rules{ anonymous };
        }

        if( exists $_rules{ single }) {
            $force_single = delete $_rules{ single };
        }

        if( exists $_rules{ munge }) {
            my $m = delete $_rules{ munge };
            if( ref $m) { # code ref
                $munger = $m;
            } elsif( $options->{mungers}->{ $m }) { # name
                $munger = $options->{mungers}->{ $m };
            } else {
                croak "Got an unknown munger name '$m'";
            }
        }

        my $debug;

        if( delete $_rules{ debug }) {
            $debug = 1;
        }

        my $single_query;
        my $attribute;
        #warn Dumper \%_rules;
        if( exists $_rules{ query } ) {
            $single_query = delete $_rules{ query };

        #} elsif( keys %_rules == 1 ) {
        #    # Single query that likely is anonymous
        #    warn "Making up query because we only have a single rule?!";
        #    ($single_query) = keys %_rules;
        }

        if( defined $single_query ) {
            # Fix up the query
            if( $single_query && $single_query !~ m!/! ) {
                # We have something like a CSS selector
                if( $single_query =~ m!^(.*)\@([\w-]+)\z! ) {
                    # we have a query for an attribute, and selector_to_xpath doesn't like attributes-with-dashes :(
                    $single_query = $1;
                    $attribute = $2;
                };
                $single_query = selector_to_xpath($single_query);
            }
            # Queries always are relative to the current node
            # except if they are absolute to the root element. Not ideal.
            if($single_query =~ m!^//! ) {
                $single_query = ".$single_query";
            }

            # If we stripped off the attribute before, tack it on again
            if( defined $attribute ) {
                $single_query .= sprintf '/@%s', $attribute;
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
            my $query = $single_query;
            croak "Nothing to do at " . join " -> ", $context->{path}->@*
                if @subitems > 1;
            my $name = $subitems[0];

            if( $options->{debug} or $debug) {
                my $str = $node->toString;
                $str =~ s!\s+! !msg; # compress the string slightly
                if( length $str > 80 ) {
                    substr( $str, 77 ) = '...';
                }
                say "$name [ $query ] $str"
            }

            push $context->{path}->@*, $name;

            # Make query relative to our context
            if( $query =~ m!^//! ) {
                $query = ".$query";
            }

            @subitems = values %_rules;

            my $items = $node->findnodes( $query );

            my @found = $items->get_nodelist;
            if( $debug ) {
                say sprintf "Found %d nodes for $query", scalar @found;
            }

            if( defined $force_index) {
                @found = $found[ $force_index-1 ];
            } elsif( $force_single ) {
                if( @found > 1 ) {
                    use Data::Dumper;
                    warn Dumper \@found;
                    croak "More than one element found for " . join " -> ", $context->{path}->@*;
                }
            }

            for my $item (@found) {
                next unless $item;
                if( @subitems) {
                    for my $rule (@subitems) {
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
                            push @res, { $name => $munger->( $val ) };

                        }
                    }
                } else {
                    my $val = maybe_attr( $item, $attribute );

                    if( $anonymous ) {
                        push @res, $munger->( $val );
                    } else {
                        if( ! $name ) {
                            push @res, $munger->( $val );
                        } else {
                            push @res, { $name => $munger->( $val )};
                        }
                    }
                }
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
