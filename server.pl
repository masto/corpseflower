#!/usr/bin/perl

use warnings;
use strict;

use AnyEvent::Socket;
use AnyEvent::Handle;

use lib 'lib';

use Connection;
use Friend;

use JSON;

my $BUF_SIZE = 1024;
my $IDLE_INTERVAL   = 600; # How often to run idle check
my $IDLE_PING       = 1; # How many intervals before sending ping
my $IDLE_DISCONNECT = 3; # How many intervals before disconnect

my %connections;
my %friends;

sub hello_new_connection {
  my $connection = shift;

  $connection->print(<<'END_HELLO'
welcome to corpseflower.

commands:
  /help - this
  /name <identify yourself> - do this first
  /blurb <set blurb>
  /say <something public>
  /pong - respond to pings or die
  /who
  /bye
  or just say something

END_HELLO
);
}

sub close_connection {
  my ($h, $message) = @_;
  # Closed
  my $connection = $connections{$h};
  print STDERR "Connection closed $message\n";
  my $name;
  my $friend = $connection->friend;
  if ($friend) {
    $friend->online(0);
    tell_everyone($connection, "bye " . $friend->name);
    $name = $friend->name;
  }
  delete $connections{$h};
};

sub tell_everyone {
  my ($connection, $line) = @_;

  foreach my $out (values %connections) {
    if ($connection->is_valid_peer($out)) {
      $out->print("$line\n");
    }
  }
}

sub report_friends {
  my $connection = shift;

  my $friend = $connection->friend or return;
  my $anyone = 0;
  foreach my $other (values %friends) {
    if ($friend->is_peer($other)) {
      $connection->print($other->friend_string . "\n");
      $anyone++ if $friend->online;
    }
  }

  unless ($anyone) {
    $connection->print("Nobody here but you, chicken.\n");
  }
}

sub parse_name {
  my ($connection, $cmd) = @_;

  if (my ($name) = $cmd =~ /(.+)/) {
    my $friend;
    # Does this connection already belong to someone?
    unless ($friend = $connection->friend) {
      my $udid = $name; # lazy
      # No... so do we know this UDID?
      if ($friend = $friends{$udid}) {
        # Kick any old connections for the same user
        foreach my $stale (values %connections) {
          if ($stale->friend && $stale->friend->is_self($friend)) {
            print STDERR "Dropping friend's old connection $stale\n";
            $stale->print("Your doppelganger just signed on.\n");
            $stale->close;
          }
        }
      }
      else {
        # It's someone new
        print STDERR "Making new friend $udid\n";
        $friends{$udid} = $friend = Friend->new({ udid => $udid,
                                                  name => $name });
      }

      print STDERR "$connection <- $friend\n";
      $connection->friend($friend);
    }

    $friend->online(1);
    $friend->lastseen(time);

    $connection->print("hi $name\n");
    tell_everyone($connection, $friend->friend_string);
    report_friends($connection);
  }
  else {
    $connection->print("parse_name failed\n");
  }
}

sub parse_blurb {
  my ($connection, $cmd) = @_;

  my $friend = $connection->friend or return;
  if (my ($blurb) = $cmd =~ /^(.+)$/) {
    $friend->blurb($blurb);
    $connection->print("You set your blurb to [$blurb]\n");
  }
  else {
    $friend->blurb(undef);
    $connection->print("You cleared your blurb.\n");
  }
  tell_everyone($connection, $friend->blurb_string);
}

sub parse_say {
  my ($connection, $cmd) = @_;

  my $friend = $connection->friend or do {
    $connection->print("Identify yourself with /name first.\n");
    return;
  };
  if (my ($said) = $cmd =~ /^(.+)$/) {
    tell_everyone($connection, $friend->name . ": $said");
  }
  else {
    $connection->print("Say what?\n");
  }
}

sub do_pong {
  my $connection = shift;

  my $friend = $connection->friend or return;
  $friend->lastseen(time);
  $connection->print("Glad you're alive.\n");
}

sub do_bye {
  my $connection = shift;

  my $friend = $connection->friend or return;
  $connection->print("Nice knowing you.\n");
  close_connection($connection->handle, "Terminated by client");
}

my $quit_cond = AnyEvent->condvar;

print STDERR "Beginning loop...\n";

tcp_server undef, 9988, sub {
  my ($fh, $host, $port) = @_;

  # Incoming connection
  print STDERR "New connection\n";

  my $new_handle; $new_handle = AnyEvent::Handle->new(
    fh => $fh,
    on_read => sub {
      shift->push_read(line => sub {
        my ($h, $line) = @_;

        print STDERR "<$line>\n";

        my $connection = $connections{$h};
        $connection->idle(undef);
        if (my ($cmd, $rest) = $line =~ /^(\S+)\s*(.*)$/) {
          if ($cmd eq "/name") {
            parse_name($connection, $rest);
          }
          elsif ($cmd eq "/help") {
            hello_new_connection($connection);
          }
          elsif ($cmd eq "/blurb") {
            parse_blurb($connection, $rest);
          }
          elsif ($cmd eq "/say") {
            parse_say($connection, $rest);
          }
          elsif ($cmd eq "/who") {
            report_friends($connection);
          }
          elsif ($cmd eq "/pong") {
            do_pong($connection);
          }
          elsif ($cmd eq "/bye") {
            do_bye($connection);
          }
          elsif ($cmd =~ m|^/|) {
            print STDERR "Unknown command\n";
            $connection->print("Unknown command.\n");
          }
          else {
            parse_say($connection, $line);
          }
        }
        else {
          $connection->print("Parse error.\n");
        }
      });
    },
    on_error => sub { close_connection(@_[0, 2]); },
    on_eof => sub { close_connection(shift, "EOF"); }
  );

  my $connection = Connection->new({
    handle => $new_handle
  });
  $connections{$new_handle} = $connection;

  hello_new_connection($connection);
};

# Idle disconnect timer
my $idle_timer; $idle_timer = AnyEvent->timer(
  after => $IDLE_INTERVAL,
  interval => $IDLE_INTERVAL,
  cb => sub {
    #print STDERR "timer woke up\n";
    # Copy before iterating as %connections is modified by the loop
    my @conns = values %connections;
    foreach my $conn (@conns) {
      my $idle = $conn->idle || 0;

      # Do disconnect...
      if ($idle >= $IDLE_DISCONNECT) {
        print STDERR "Closing unresponsive connection $conn\n";
        $conn->print("You didn't say '/pong', socket-waster.\n");
        close_connection($conn->handle, "Ping timeout");
      }
      # Do ping...
      elsif ($idle == $IDLE_PING) {
        print STDERR "Pinging quiet connection $conn\n";
        $conn->print("ping at " . scalar(gmtime) . " UTC\n");
      }

      # Do bump idle...
      $idle++;

      $conn->idle($idle);
    }
  }
);

$quit_cond->recv;

print STDERR "Terminating: $!\n";
