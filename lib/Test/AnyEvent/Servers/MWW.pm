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
use Test::AnyEvent::Workaholicd;

sub new_from_root_d {
    return bless {workaholicd_boot_cv => AE::cv, root_d => $_[1]}, $_[0];
}

sub root_d {
    if (@_ > 1) {
        $_[0]->{root_d} = $_[1];
    }
    return $_[0]->{root_d};
}

sub _before_start_server {
    #
}

# ------ Perl ------

sub perl {
    if (@_ > 1) {
        $_[0]->{perl} = $_[1];
    }
    return $_[0]->{perl} || 'perl';
}

sub perl_inc {
    if (@_ > 1) {
        $_[0]->{perl_inc} = $_[1];
    }
    return $_[0]->{perl_inc} || [];
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
    unless ($self->{before_start_server_invoked}) {
        $self->{before_start_server_invoked} = 1;
        $self->_before_start_server;
    }
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

sub web_server {
    return $_[0]->{web_server} ||= Test::AnyEvent::plackup->new;
}

sub _start_web_server {
    my $self = shift;

    my $server = $self->web_server;
    $server->perl($self->perl);
    $server->perl_inc($self->perl_inc);
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

sub workaholicd {
    return $_[0]->{workaholicd} ||= Test::AnyEvent::Workaholicd->new_from_root_d($_[0]->root_d);
}

sub workaholicd_f {
    return shift->workaholicd->server_pl_f(@_);
}

sub workaholicd_conf_f {
    return shift->workaholicd->config_pl_f(@_);
}

sub _set_workaholicd_options {
    my ($self, $server) = @_;
    $server->set_env(MYSQL_DSNS_JSON => $self->dsns_json_f->stringify);
    $server->set_env(WEB_HOSTNAME => $self->web_hostname);
    $server->set_env(WEB_PORT => $self->web_port);
}

sub start_workaholicd_as_cv {
    weaken(my $self = shift);
    my $cv = AE::cv;
    $self->{workaholicd_boot_cv}->cb(sub {
        my $server = $self->workaholicd;
        $server->perl($self->perl);
        $server->perl_inc($self->perl_inc);
        $self->_set_workaholicd_options($server);
        my ($cv1, $cv2) = $server->start_server;
        $self->{workaholicd_stop_cv} = AE::cv;
        $cv2->cb(sub {
            if (my $return = $_[0]->recv >> 8) {
                die "Can't start workaholicd: " . $return;
            }
            $self->{workaholicd_stop_cv}->send;
        });
    }) unless $self->{workaholicd_started}++;
    $cv->send;
    return $cv;
}

# ------ Contextial ------

sub web_hostname {
    return 'localhost';
}

sub web_port {
    return $_[0]->web_server->port;
}

sub web_host {
    return $_[0]->web_hostname . ':' . $_[0]->web_server->port;
}

sub onstdout {
    my $self = shift;
    $self->mysql_server->onstdout(@_);
    $self->web_server->onstdout(@_);
    $self->workaholicd->onstdout(@_);
}

sub onstderr {
    my $self = shift;
    $self->mysql_server->onstderr(@_);
    $self->web_server->onstderr(@_);
    $self->workaholicd->onstderr(@_);
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
        $self->workaholicd->stop_server;
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

sub stop_server {
    return $_[0]->context_end($_[1]);
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
