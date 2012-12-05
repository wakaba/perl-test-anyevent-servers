package Test::AnyEvent::Servers;
use strict;
use warnings;
use warnings FATAL => 'recursion';
use Carp;
use AnyEvent;

sub new ($) {
  return bless {}, $_[0];
} # new

sub add ($$%) {
  my ($self, $name, $opts) = @_;
  if ($self->{state}->{$name}) {
    croak "Server |$name| is already registered";
  }
  $self->{opts}->{$name} = $opts;
  $self->{state}->{$name} = {current => 'stopped'};
} # add

sub get ($$) {
  my ($self, $name) = @_;
  my $state = $self->{state}->{$name} or return undef;
  return $state->{server}; # or undef
} # get

sub start_as_cv ($$) {
  my ($self, $name) = @_;
  my $cv = AE::cv;

  my $state = $self->{state}->{$name};
  my $opts = $self->{opts}->{$name};

  unless ($state) {
    croak "Server |$name| is not registered";
  }

  my $cv_req = AE::cv;
  $cv_req->begin;
  for (grep { $opts->{start_require}->{$_} } keys %{$opts->{start_require} or {}}) {
    $cv_req->begin;
    $self->start_as_cv ($_)->cb (sub { $cv_req->end });
  }
  $cv_req->end;

  $cv_req->cb (sub {
    if ($state->{current} eq 'started') {
      $cv->send (Test::AnyEvent::Servers::Result->new);
      return;
    }

    if ($state->{current} eq 'starting') {
      push @{$state->{on_start} ||= []}, sub {
        $cv->send (Test::AnyEvent::Servers::Result->new);
      };
      return;
    }

    if ($state->{current} eq 'stopping') {
      push @{$state->{on_stop_then_start} ||= []}, sub {
        $cv->send (Test::AnyEvent::Servers::Result->new);
      };
      return;
    }

    my $server = $state->{server} ||= do {
      my $method = $opts->{constructor_name} || 'new';
      my $class = $opts->{class};
      eval qq{ require $class } or die $@;
      $class->$method;
    };
    
    {
      $state->{current} = 'starting';
      my $method = $opts->{starter_name} || 'start_as_cv';
      $server->$method->cb(sub {
        # XXX failure
        $state->{current} = 'started';
        for (@{delete $state->{on_start} or []}) {
          $_->();
        }
        $cv->send (Test::AnyEvent::Servers::Result->new);
        if (my $codes = delete $state->{on_start_then_stop}) {
          $self->stop_as_cv ($name)->cb (sub {
            for (@$codes) {
              $_->();
            }
          });
        }
      });
      return;
    }
  });
  return $cv;
} # start_as_cv

sub stop_as_cv ($$) {
  my ($self, $name) = @_;
  my $cv = AE::cv;
  
  my $state = $self->{state}->{$name};
  unless ($state) {
    croak "Server |$name| is not registerd";
  }

  if ($state->{current} eq 'stopped') {
    $cv->send (Test::AnyEvent::Servers::Result->new);
    return $cv;
  }

  if ($state->{current} eq 'stopping') {
    push @{$state->{on_stop} ||= []}, sub {
      $cv->send (Test::AnyEvent::Servers::Result->new);
    };
    return $cv;
  }

  if ($state->{current} eq 'starting') {
    push @{$state->{on_start_then_stop} ||= []}, sub {
      $cv->send (Test::AnyEvent::Servers::Result->new);
    };
    return $cv;
  }

  {
    $state->{current} = 'stopping';
    my $opts = $self->{opts}->{$name};
    my $method = $opts->{stopper_name} || 'stop_as_cv';
    $state->{server}->$method->cb (sub {
      # XXX failure
      $state->{current} = 'stopped';
      for (@{delete $state->{on_stop} or []}) {
        $_->();
      }
      $cv->send (Test::AnyEvent::Servers::Result->new);
      if (my $codes = delete $state->{on_stop_then_start}) {
        $self->start_as_cv ($name)->cb (sub {
          for (@$codes) {
            $_->();
          }
        });
      }
    });
    return $cv;
  }
} # stop_as_cv

package Test::AnyEvent::Servers::Result;

sub new ($;%) {
  my $class = shift;
  return bless {@_}, $class;
} # new

1;

=head1 LICENSE

Copyright 2012 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
