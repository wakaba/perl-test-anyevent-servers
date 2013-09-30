package Test::AnyEvent::Servers;
use strict;
use warnings;
use warnings FATAL => 'recursion';
use Carp;
use AnyEvent;

sub new ($) {
  return bless {pid => $$}, $_[0];
} # new

sub add ($$%) {
  my ($self, $name, $opts) = @_;
  if ($self->{state}->{$name}) {
    croak "Server |$name| is already registered";
  }
  unless ($opts->{class}) {
    croak "|class| of server |$name| is not specified";
  }
  $self->{opts}->{$name} = $opts;
  $self->{state}->{$name} = {current => 'stopped'};
} # add

sub get ($$) {
  my ($self, $name) = @_;
  my $state = $self->{state}->{$name};
  unless ($state) {
    croak "Server |$name| is not registered";
  }

  my $opts = $self->{opts}->{$name};
  return $state->{server} ||= do {
    my $method = $opts->{construct} || $opts->{constructor_name} || 'new';
    my $class = $opts->{class};
    eval qq{ require $class } or die $@;
    my $server = $class->$method;
    ($opts->{on_init} or sub { })->($self, $server);
    $server;
  };
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

    my $server = $self->get ($name);
    
    {
      $state->{current} = 'starting';
      my $method = $opts->{starter_name} || 'start_as_cv';
      ($opts->{start_as_cv} || $server->can ($method) || croak "No starter method for $name ($method)")->($server)->cb (sub {
        # XXX failure ($opts->{is_error})
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
    ($opts->{stop_as_cv} || $state->{server}->can ($method) || croak "No stopper method for |$name| ($method)")->($state->{server})->cb (sub {
      # XXX failure ($opts->{is_error})
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

sub stop_all_as_cv ($) {
  my $self = shift;
  my $cv = AE::cv;
  $cv->begin;
  for (keys %{$self->{state} or {}}) {
    unless ($self->{state}->{$_}->{current} eq 'stopped') {
      $cv->begin;
      $self->stop_as_cv ($_)->cb (sub { $cv->end });
    }
  }
  $cv->end;
  return $cv;
} # stop_all_as_cv

sub DESTROY ($) {
  $_[0]->stop_all_as_cv if ($_[0]->{pid} || 0) == $$;
} # DESTORY

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
