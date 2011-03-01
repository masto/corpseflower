package Connection;

# Manages state for a single connection

use base qw(Class::Accessor);

use strict;

__PACKAGE__->mk_accessors(qw(
  handle friend idle
));

sub new {
  my($proto, $fields) = @_;
  my($class) = ref $proto || $proto;

  $fields = {} unless defined $fields;

  # make a copy of $fields.
  bless {%$fields}, $class;
}

sub is_valid_peer {
  my ($self, $other) = @_;

  return $self->friend &&
         $other->friend &&
         $self->friend->is_peer($other->friend);
}

sub close {
  my $self = shift;

  $self->handle->push_shutdown;
}

sub print {
  shift->handle->push_write(@_);
}

1;
