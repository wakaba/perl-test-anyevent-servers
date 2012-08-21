package Test::AnyEvent::Servers::MWW;
use strict;
use warnings;
use Path::Class;
use AnyEvent;
use AnyEvent::Util;
use MIME::Base64 qw(encode_base64);
use Scalar::Util qw(weaken);
use File::Temp;
use Test::AnyEvent::MySQL::CreateDatabase;
use Test::AnyEvent::plackup;

sub new_from_root_d {
    return bless {workaholicd_boot_cv => AE::cv, root_d => $_[1]}, $_[0];
}

sub root_d {
    if (@_ > 1) {
        $_[0]->{root_d} = $_[1];
    }
    return $_[0]->{root_d};
}

# ------ MySQL server ------

sub prep_f {
    my $self = shift;
    return $self->{prep_f} ||= $self->root_d->file('db', 'preparation.txt');
}

sub mysql_server {
    my $self = shift;
    return $self->{mysql_server} ||= Test::AnyEvent::MySQL::CreateDatabase->new;
}

sub dsns_json_f {
    my $self = shift;
    return $self->mysql_server->json_f;
}

sub _start_mysql_server {
    weaken(my $self = shift);
    $self->{mysql_cv} = $self->mysql_server->prep_f_to_cv($self->prep_f);
}

sub start_mysql_server_as_cv {
    weaken(my $self = shift);
    
    $self->_start_mysql_server;

    my $cv = AE::cv;
    $cv->begin(sub { $_[0]->send($self) });
    $cv->begin;
    $self->{mysql_cv}->cb(sub {
        $self->{mysql_context} = $_[0]->recv;
        $cv->end;
    });
    $cv->end;

    return $cv;
}

# ------ Web server ------

sub psgi_f {
    my $self = shift;
    return $self->{psgi_f} ||= $self->root_d->file('bin', 'server.psgi');
}

sub _set_web_server_options {
    my ($self, $server) = @_;
    $server->set_env(MYSQL_DSNS_JSON => $self->dsns_json_f->stringify);
}

sub _start_web_server {
    my $self = shift;

    $self->{web_server} = my $server = Test::AnyEvent::plackup->new;
    $server->app($self->psgi_f);
    $self->_set_web_server_options($server);

    $self->{web_start_cv} = my $cv1 = AE::cv;
    $self->{web_stop_cv} = my $cv2 = AE::cv;

    my ($start_cv, $stop_cv) = $server->start_server;
    $start_cv->cb(sub {
        my $cv = $cv1;
        undef $cv1;
        $cv->send;
    });
    $stop_cv->cb(sub {
        $cv1->send if $cv1;
        $cv2->send;
    });
}

sub start_mysql_and_web_servers_as_cv {
    weaken(my $self = shift);

    $self->_start_mysql_server;

    my $cv = AE::cv;
    $cv->begin(sub { $_[0]->send($self) });
    $cv->begin;
    $self->{mysql_cv}->cb(sub {
        $self->{mysql_context} = $_[0]->recv;
        $self->_start_web_server;
        $self->{workaholicd_boot_cv}->send;
        $self->{web_start_cv}->cb(sub {
            $cv->end;
        });
    });
    $cv->end;

    return $cv;
}

# ------ Workaholicd ------

sub workaholicd_f {
    my $self = shift;
    if (@_) {
        $self->{workaholicd_f} = shift;
    }
    return $self->{workaholicd_f} ||= $self->root_d->file('bin', 'workaholicd.pl');
}

sub workaholicd_conf_f {
    my $self = shift;
    return $self->{workaholicd_conf_f} ||= $self->root_d->file('config', 'workaholicd.pl');
}

sub _set_workaholicd_options {
    my ($self, $envs) = @_;
    $envs->{MYSQL_DSNS_JSON} = $self->dsns_json_f->stringify;
    $envs->{WEB_HOSTNAME} = $self->web_hostname;
    $envs->{WEB_PORT} = $self->web_port;
}

sub start_workaholicd_as_cv {
    weaken(my $self = shift);
    my $cv = AE::cv;
    $self->{workaholicd_boot_cv}->cb(sub {
        my $envs = {%ENV};
        $self->_set_workaholicd_options($envs);
        
        my $pid;
        $self->{workaholicd_cv} = run_cmd
            [
                'perl',
                $self->workaholicd_f->stringify, 
                $self->workaholicd_conf_f->stringify,
            ],
            '$$' => \$pid;
        $self->{workaholicd_stop_cv} = AE::cv;
        $self->{workaholicd_cv}->cb(sub {
            if (my $return = $_[0]->recv >> 8) {
                die "Can't start workaholicd: " . $return;
            }
            $self->{workaholicd_stop_cv}->send;
        });
        $self->{workaholicd_pid} = $pid;
    });
    $cv->send;
    return $cv;
}

# ------ Contextial ------

sub web_hostname {
    return 'localhost';
}

sub web_port {
    return $_[0]->{web_server}->port;
}

sub web_host {
    return $_[0]->web_hostname . ':' . $_[0]->{web_server}->port;
}

sub context_begin {
    $_[0]->{rc}++;
    if ($_[0]->{mysql_context}) {
        $_[0]->{mysql_context}->context_begin($_[1]);
    } else {
        $_[1]->();
    }
}

sub context_end {
    my ($self, $cb) = @_;
    my $cb2 = sub {
        if ($self->{mysql_context}) {
            $self->{mysql_context}->context_end($cb);
        } else {
            $cb->() if $cb;
        }
        undef $self;
    };
    if (--$self->{rc} > 0) {
        $cb2->();
    } else {
        if ($self->{workaholicd_pid}) {
            kill 15, $self->{workaholicd_pid}; # SIGTERM
        }
        if ($self->{web_stop_cv}) {
            $self->{web_stop_cv}->cb(sub {
                $cb2->();
            });
        } else {
            $cb2->();
        }
        if ($self->{workaholicd_stop_cv}) {
            $self->{workaholicd_stop_cv}->cb(sub {
                $self->{web_server}->stop_server if $self->{web_server};
            });
        } else {
            $self->{web_server}->stop_server if $self->{web_server};
        }
    }
}

sub DESTROY {
    {
        local $@;
        eval { die };
        if ($@ =~ /during global destruction/) {
            warn "Detected (possibly) memory leak";
        }
    }
    $_[0]->context_end;
}

1;
