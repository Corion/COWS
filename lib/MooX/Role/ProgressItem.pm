package MooX::Role::ProgressItem 0.01;
use Moo::Role;
use 5.020;
with 'MooX::Role::EventEmitter';
use feature 'signatures';
no warnings 'experimental::signatures';

=head1 NAME

MooX::Role::ProgressItem - store information about some progress

=head1 SYNOPSIS

  package My::Download {
    use Moo 2;
    with 'MooX::Role::ProgressItem';

    sub do_request($self) {
      my $total = 10;
      $self->start($total);

      for my $pos ( 1..$total ) {
        $self->progress( $pos );
      };

      $self->finish();
      return { body => 'Hello World' };
    }
  }

  my $download = My::Download->new(
      GET => 'https://example.com';
  );
  $download->on( 'start' => sub($info) {
    say sprintf 'started: %s', $info->{item}->url;
  });
  $download->on( 'progress' => sub($info) {
    say sprintf '%02f %%: %s', $info->{item}->percent;
  });
  $download->do_request();

=head1 METHODS

=head2 C<< ->new >>



=cut

has 'total' => (
    is => 'rw',
    default => 0,
);

# Stores the last invocation
has 'curr' => (
    is => 'rw',
    default => 0,
);

has 'visual' => (
    is => 'rw',
    default => '<item>',
);

has 'action' => (
    is => 'rw',
    default => '<unknown>',
);

has 'progress_state' => (
    is => 'rw',
);

# Can we ->get this item? What for?

sub percent( $self, $curr=$self->curr ) {
    if( my $total = $self->total ) {
        return ($curr/$total)*100
    } else {
        return undef
    }
}

sub start($self, $total = undef) {
    $self->total( $total );
    $self->curr( 0 );
    $self->emit( start => { item => $self } );
}

sub progress($self,$curr, $action=undef) {
    $self->curr( $curr );
    if( ! $self->progress_state ) {
        $self->emit( start => { item => $self } );
        $self->progress_state( 'progressing' );
    }
    if( $action ) {
        $self->action($action);
    }
    $self->emit( progress => { item => $self, curr => $curr, action => $action } );
}

sub finish( $self ) {
    $self->progress_state( 'finished' );
    $self->emit( finish => { item => $self } );
}

=head1 EVENTS

=head2 C<start>

  $item->on( start => sub($info) {
      my $item = $info->{item};
      ...
  });

Issued when processing the item has started. Usually emitted when
C< ->start() > is called. Automatically emitted the first time
C< ->progress() > is called.

=head2 C<progress>

  $item->on( progress => sub($info) {
      my $item = $info->{item};
      ...
  });

Emitted when the item progresses forward or backward, usually when
C< ->progress($pos) > is called.

=head2 C<finish>

  $item->on( finish => sub($info) {
      my $item = $info->{item};
      ...
  });

Issued when the item is done. Usually emitted when
C< ->finish() > is called.

=cut

1;
