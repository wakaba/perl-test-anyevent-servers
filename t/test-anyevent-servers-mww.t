use strict;
use warnings;
use Path::Class;
use lib glob file(__FILE__)->dir->parent->subdir('t_deps', 'modules', '*', 'lib')->stringify;
use File::Temp;
use Test::X1;
use Test::More;
use Test::AnyEvent::Servers::MWW;
use JSON::Functions::XS qw(json_bytes2perl);

test {
    my $c = shift;

    my $temp_dir_name = File::Temp->newdir;
    my $root_d = dir($temp_dir_name);

    {
        $root_d->subdir('db')->mkpath;
        my $file = $root_d->file('db', 'preparation.txt')->openw;
        print $file "db hoge\n";
        close $file;
    }

    my $server = Test::AnyEvent::Servers::MWW->new_from_root_d($root_d);
    my $cv = $server->start_mysql_server_as_cv;

    $cv->cb(sub {
        test {
            my $json = json_bytes2perl scalar $server->dsns_json_f->slurp;
            ok $json->{dsns}->{hoge};
            done $c;
            undef $c;
            undef $temp_dir_name;
        } $c;
    });
} n => 1, name => 'start_mysql_server_as_cv';

test {
    my $c = shift;

    my $temp_dir_name = File::Temp->newdir;
    my $root_d = dir($temp_dir_name);

    {
        $root_d->subdir('db')->mkpath;
        my $file = $root_d->file('db', 'preparation.txt')->openw;
        print $file "db hoge\n";
        close $file;
    }

    my $server = Test::AnyEvent::Servers::MWW->new_from_root_d($root_d);
    my $cv = $server->start_mysql_and_web_servers_as_cv;

    $cv->cb(sub {
        test {
            my $json = json_bytes2perl scalar $server->dsns_json_f->slurp;
            ok $json->{dsns}->{hoge};
            done $c;
            undef $c;
            undef $temp_dir_name;
        } $c;
    });
} n => 1, name => 'start_mysql_and_web_servers_as_cv';

test {
    my $c = shift;

    my $temp_dir_name = File::Temp->newdir;
    my $root_d = dir($temp_dir_name);

    {
        $root_d->subdir('db')->mkpath;
        my $file = $root_d->file('db', 'preparation.txt')->openw;
        print $file "db hoge\n";
        close $file;
    }

    my $which = file(__FILE__)->dir->parent->file('local', 'bin', 'which');
    my $plackup = `$which plackup`;
    chomp $plackup;

    my $server = Test::AnyEvent::Servers::MWW->new_from_root_d($root_d);
    $server->perl(file(__FILE__)->dir->parent->file('perl'));
    $server->web_server->plackup($plackup);
    $server->workaholicd_f(file(__FILE__)->dir->parent->subdir('t_deps', 'modules', 'workaholicd', 'bin')->file('workaholicd.pl'));
    my $cv1 = $server->start_mysql_and_web_servers_as_cv;
    my $cv2 = $server->start_workaholicd_as_cv;
    my $cv = AE::cv;
    $cv->begin(sub {
        test {
            done $c;
            undef $c;
            undef $temp_dir_name;
        } $c;
    });

    $cv->begin;
    $cv1->cb(sub {
        test {
            my $json = json_bytes2perl scalar $server->dsns_json_f->slurp;
            ok $json->{dsns}->{hoge};
            $cv->end;
        } $c;
    });

    $cv->begin;
    $cv2->cb(sub {
        test {
            ok 1;
            $cv->end;
        } $c;
    });

    $cv->end;
} n => 2, name => 'start_mysql_and_web_and_workaholicd_servers_as_cv';

run_tests;
