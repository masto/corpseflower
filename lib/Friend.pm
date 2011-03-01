package Friend;

# Someone with a UDID

use base qw(Class::Accessor);

use strict;

__PACKAGE__->mk_accessors(qw(
  udid name online blurb lastseen
));

sub new {
  my ($proto, $fields) = @_;
  my $class = ref $proto || $proto;

  $fields = {} unless defined $fields;

  $fields->{name} ||= "Unknown";
  $fields->{url} ||= "";

  # make a copy of $fields.
  bless {%$fields}, $class;
}

sub is_self {
  my ($self, $other) = @_;

  return $self->udid eq $other->udid;
}

sub is_peer {
  my ($self, $other) = @_;

  return ! $self->is_self($other);
}

sub friend_string {
  my $self = shift;

  return sprintf("%s [%s] is %s, seen %s UTC",
                 $self->name,
                 $self->blurb,
                 $self->online ? "online" : "offline",
                 scalar(gmtime $self->lastseen));
}

sub blurb_string {
  my $self = shift;

  return sprintf("%s set blurb to [%s]",
                 $self->name,
                 $self->blurb);
}

1;
