use strict;
use warnings;
use Path::Class;
use lib file (__FILE__)->dir->parent->subdir ('lib')->stringify;
use lib glob file (__FILE__)->dir->parent->subdir ('t', 'modules', '*', 'lib')->stringify;
use Test::More;
use Test::X1;
use Test::AnyEvent::Servers;

{
  package test::server1;
  use AnyEvent;
  $INC{'test/server1.pm'} = 1;
  
  sub new ($) {
    return bless {}, $_[0];
  } # new

  sub start_as_cv {
    my $self = shift;
    my $cv = AE::cv;
    my $timer; $timer = AE::timer 0, 0.01, sub {
      undef $timer;
      $self->{started}++;
      $cv->send;
    };
    return $cv;
  } # start_as_cv

  sub stop_as_cv {
    my $self = shift;
    my $cv = AE::cv;
    my $timer; $timer = AE::timer 0, 0.01, sub {
      undef $timer;
      $self->{stopped}++;
      $cv->send;
    };
    return $cv;
  } # stop_as_cv
}

test {
  my $c = shift;
  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {});
  eval {
    $servers->add (server1 => {});
  };
  ok $@;
  done $c;
} n => 1;

test {
  my $c = shift;
  my $servers = Test::AnyEvent::Servers->new;
  eval {
    $servers->start_as_cv ('foo')
  };
  ok $@;
  done $c;
} n => 1;

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server1'});

  $servers->start_as_cv ('server1')->cb (sub {
    test {
      my $server = $servers->get ('server1');
      isa_ok $server, 'test::server1';
      ok $server->{started};
      done $c;
      undef $c;
    } $c;
  });
} n => 2;

{
  package test::server2;
  use AnyEvent;
  $INC{'test/server2.pm'} = 1;
  
  sub new ($) {
    return bless {}, $_[0];
  } # new

  sub start_as_cv {
    my $self = shift;
    my $cv = AE::cv;
    $self->{start_cv} = AE::cv;
    $self->{start_cv}->cb (sub {
      $self->{started}++;
      $cv->send;
    });
    return $cv;
  } # start_as_cv

  sub stop_as_cv {
    my $self = shift;
    my $cv = AE::cv;
    $self->{stop_cv} = AE::cv;
    $self->{stop_cv}->cb (sub {
      $self->{stopped}++;
      $cv->send;
    });
    return $cv;
  } # stop_as_cv
}

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server2'});

  my $cv = AE::cv;
  $cv->begin (sub { done $c; undef $c });
  $cv->begin;
  $servers->start_as_cv ('server1')->cb (sub {
    test {
      my $server = $servers->get ('server1');
      isa_ok $server, 'test::server2';
      is $server->{started}, 1;
      $cv->end;
    } $c;
  });
  $cv->begin;
  $servers->start_as_cv ('server1')->cb (sub {
    test {
      my $server = $servers->get ('server1');
      isa_ok $server, 'test::server2';
      is $server->{started}, 1;
      $cv->end;
    } $c;
  });
  $cv->end;
  $servers->get ('server1')->{start_cv}->send;
} n => 4, name => 'start_as_cv invoked while starting';

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server1'});

  my $cv1 = AE::cv;
  $servers->start_as_cv ('server1')->cb (sub {
    test {
      my $server = $servers->get ('server1');
      isa_ok $server, 'test::server1';
      is $server->{started}, 1;
      $cv1->send;
    } $c;
  });

  $cv1->cb (sub {
    $servers->start_as_cv ('server1')->cb (sub {
      test {
        my $server = $servers->get ('server1');
        isa_ok $server, 'test::server1';
        is $server->{started}, 1;
        done $c;
        undef $c;
      } $c;
    });
  });
} n => 4, name => 'start_as_cv invoked after started';

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server1'});
  $servers->add (server2 => {class => 'test::server1'});

  my $cv = AE::cv;
  $cv->begin (sub { done $c; undef $c });
  $cv->begin;
  $servers->start_as_cv ('server1')->cb (sub {
    test {
      my $server = $servers->get ('server1');
      isa_ok $server, 'test::server1';
      ok $server->{started};
      $cv->end;
    } $c;
  });
  $cv->begin;
  $servers->start_as_cv ('server2')->cb (sub {
    test {
      my $server = $servers->get ('server2');
      isa_ok $server, 'test::server1';
      ok $server->{started};
      $cv->end;
    } $c;
  });
  $cv->end;
} n => 4;

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server1'});

  $servers->start_as_cv ('server1')->cb (sub {
    $servers->stop_as_cv ('server1')->cb (sub {
      test {
        my $server = $servers->get ('server1');
        isa_ok $server, 'test::server1';
        is $server->{started}, 1;
        is $server->{stopped}, 1;
        done $c;
        undef $c;
      } $c;
    });
  });
} n => 3;

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server1'});

  $servers->start_as_cv ('server1')->cb (sub {
    $servers->stop_as_cv ('server1')->cb (sub {
      $servers->stop_as_cv ('server1')->cb (sub {
        test {
          my $server = $servers->get ('server1');
          isa_ok $server, 'test::server1';
          is $server->{started}, 1;
          is $server->{stopped}, 1;
          done $c;
          undef $c;
        } $c;
      });
    });
  });
} n => 3;

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server1'});

  $servers->start_as_cv ('server1')->cb (sub {
    $servers->stop_as_cv ('server1')->cb (sub {
      $servers->start_as_cv ('server1')->cb (sub {
        $servers->stop_as_cv ('server1')->cb (sub {
          test {
            my $server = $servers->get ('server1');
            isa_ok $server, 'test::server1';
            is $server->{started}, 2;
            is $server->{stopped}, 2;
            done $c;
            undef $c;
          } $c;
        });
      });
    });
  });
} n => 3;

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server1'});

  $servers->stop_as_cv ('server1')->cb (sub {
    test {
      my $server = $servers->get ('server1');
      is $server, undef; 
      done $c;
      undef $c;
    } $c;
  });
} n => 1;

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server1'});

  $servers->stop_as_cv ('server1')->cb (sub {
    $servers->start_as_cv ('server1')->cb (sub {
      test {
        my $server = $servers->get ('server1');
        isa_ok $server, 'test::server1';
        is $server->{started}, 1;
        ok !$server->{stopped};
        done $c;
        undef $c;
      } $c;
    });
  });
} n => 3;

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server2'});

  $servers->start_as_cv ('server1')->cb (sub {
    $servers->stop_as_cv ('server1')->cb (sub {
      test {
        my $server = $servers->get ('server1');
        isa_ok $server, 'test::server2';
        is $server->{started}, 1;
        is $server->{stopped}, 1;
        done $c;
        undef $c;
      } $c;
    });

    my $timer; $timer = AE::timer 0, 0.2, sub {
      my $server = $servers->get ('server1');
      $server->{stop_cv}->send;
      undef $timer;
    };
  });

  my $timer; $timer = AE::timer 0, 0.2, sub {
    test {
      my $server = $servers->get ('server1');
      isa_ok $server, 'test::server2';
      ok !$server->{started};
      ok !$server->{stopped};
      $server->{start_cv}->send;
    } $c;
    undef $timer;
  };
} n => 6;

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server2'});

  $servers->start_as_cv ('server1')->cb (sub {
    test {
      my $server = $servers->get ('server1');
      isa_ok $server, 'test::server2';
      is $server->{started}, 1;
      ok !$server->{stopped};
    } $c;

    my $cv = AE::cv;
    $cv->begin;
    $cv->begin;
    $servers->stop_as_cv ('server1')->cb (sub {
      test {
        my $server = $servers->get ('server1');
        isa_ok $server, 'test::server2';
        is $server->{started}, 1;
        is $server->{stopped}, 1;
        $cv->end;
      } $c;
    });

    $cv->begin;
    $servers->start_as_cv ('server1')->cb (sub {
      test {
        my $server = $servers->get ('server1');
        isa_ok $server, 'test::server2';
        is $server->{started}, 2;
        is $server->{stopped}, 1;
        $cv->end;
      } $c;
    });
    $cv->end;

    $cv->cb (sub { done $c; undef $c });

    my $timer; $timer = AE::timer 0, 0.2, sub {
      my $server = $servers->get ('server1');
      $server->{stop_cv}->send;
      undef $timer;
    };

    my $timer2; $timer2 = AE::timer 0, 0.4, sub {
      my $server = $servers->get ('server1');
      $server->{start_cv}->send;
      undef $timer2;
    };
  });

  my $timer; $timer = AE::timer 0, 0.2, sub {
    test {
      my $server = $servers->get ('server1');
      isa_ok $server, 'test::server2';
      ok !$server->{started};
      ok !$server->{stopped};
      $server->{start_cv}->send;
    } $c;
    undef $timer;
  };
} n => 12;

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server1'});
  $servers->add (server2 => {class => 'test::server1',
                             start_require => {server1 => 1}});
  
  $servers->start_as_cv ('server2')->cb (sub {
    test {
      is $servers->get ('server1')->{started}, 1;
      is $servers->get ('server2')->{started}, 1;
      done $c;
      undef $c;
    } $c;
  });
} n => 2;

test {
  my $c = shift;

  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server1',
                             start_require => {server2 => 1}});
  $servers->add (server2 => {class => 'test::server1',
                             start_require => {server1 => 1}});

  eval {
    $servers->start_as_cv ('server2');
  };
  like $@, qr{Deep recursion};
  ok not $servers->get ('server1');
  ok not $servers->get ('server2');
  done $c;
  undef $c;
} n => 3;

test {
  my $c = shift;
  
  my $servers = Test::AnyEvent::Servers->new;
  $servers->add (server1 => {class => 'test::server1'});
  $servers->add (server2 => {class => 'test::server1'});

  $servers->start_as_cv ('server1')->cb (sub {
    $servers->start_as_cv ('server2')->cb (sub {
      $servers->stop_all_as_cv->cb (sub {
        test {
          ok $servers->get ('server1')->{stopped};
          ok $servers->get ('server2')->{stopped};
          done $c;
          undef $c;
        } $c;
      });
    });
  });
} n => 2;

run_tests;

=head1 LICENSE

Copyright 2012 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
