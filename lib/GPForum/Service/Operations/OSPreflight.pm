package GPForum::Service::Operations::OSPreflight;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $UNKNOWN_OS      => 'unknown';
const my $SELECT_BACKEND  => 'select';
const my $MINIMUM_CPU     => 1;
const my $MINIMUM_WORKERS => 1;

has runtime => undef;

sub check {
    my ($self) = @_;

    my $profile = $self->_runtime_profile;
    return _summary( _failed_check( 'runtime', 'runtime unavailable' ) )
      if !$profile;

    my @checks = (
        _os_check($profile),       _event_backend_check($profile),
        _cpu_check($profile),      _worker_count_check($profile),
        _resource_check($profile), _socket_check($profile),
        _process_check($profile),
    );

    return _summary(@checks);
}

sub _runtime_profile {
    my ($self) = @_;

    return if !$self->runtime;

    return $self->runtime->as_hash;
}

sub _os_check {
    my ($profile) = @_;

    my $os = $profile->{os} || {};
    return _failed_check( 'os', 'OS profile missing' ) if !$os->{name};
    return _degraded_check( 'os', 'unknown OS uses conservative mode' )
      if $os->{name} eq $UNKNOWN_OS;

    return _ok_check('os');
}

sub _event_backend_check {
    my ($profile) = @_;

    my $os = $profile->{os} || {};
    return _failed_check( 'event_backend', 'event backend missing' )
      if !$os->{event_backend};
    return _degraded_check( 'event_backend', 'select backend is conservative' )
      if $os->{event_backend} eq $SELECT_BACKEND;

    return _ok_check('event_backend');
}

sub _cpu_check {
    my ($profile) = @_;

    my $os    = $profile->{os}   || {};
    my $count = $os->{cpu_count} || 0;
    return _failed_check( 'cpu_count', 'CPU count unavailable' )
      if $count < $MINIMUM_CPU;

    return _ok_check('cpu_count');
}

sub _worker_count_check {
    my ($profile) = @_;

    my $os    = $profile->{os}                  || {};
    my $count = $os->{recommended_worker_count} || 0;
    return _failed_check( 'recommended_worker_count',
        'recommended worker count unavailable' )
      if $count < $MINIMUM_WORKERS;

    return _ok_check('recommended_worker_count');
}

sub _resource_check {
    my ($profile) = @_;

    my $resources = ( $profile->{os} || {} )->{resources} || {};
    return _degraded_check( 'resources',
        'open file descriptor count unavailable' )
      if !defined $resources->{open_file_descriptors};

    return _ok_check('resources');
}

sub _socket_check {
    my ($profile) = @_;

    my $sockets = $profile->{os_sockets} || {};
    return _degraded_check( 'sockets', 'socket policy unavailable' )
      if !%{$sockets};

    for my $name ( sort keys %{$sockets} ) {
        return _degraded_check( 'sockets', "$name requested but unsupported" )
          if $sockets->{$name}{degraded};
    }

    return _ok_check('sockets');
}

sub _process_check {
    my ($profile) = @_;

    my $processes = $profile->{os_processes} || {};
    return _degraded_check( 'processes', 'process policy unavailable' )
      if !$processes->{classes};

    return _ok_check('processes');
}

sub _summary {
    my (@checks) = @_;

    return {
        status => _overall_status( \@checks ),
        checks => \@checks,
    };
}

sub _ok_check {
    my ($name) = @_;

    return { name => $name, status => 'ok' };
}

sub _degraded_check {
    my ( $name, $reason ) = @_;

    return {
        name   => $name,
        status => 'degraded',
        reason => $reason,
    };
}

sub _failed_check {
    my ( $name, $reason ) = @_;

    return {
        name   => $name,
        status => 'fail',
        reason => $reason,
    };
}

sub _overall_status {
    my ($checks) = @_;

    for my $check ( @{$checks} ) {
        return 'fail' if $check->{status} eq 'fail';
    }

    for my $check ( @{$checks} ) {
        return 'degraded' if $check->{status} eq 'degraded';
    }

    return 'ok';
}

1;
