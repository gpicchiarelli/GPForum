package GPForum::Service::Operations::Profile;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $PROFILE_VERSION    => 1;
const my $DEVELOPMENT_SECRET => 'gpforum-development-secret-change-me';
const my %ENV_TO_PROFILE => (
    development         => 'development',
    test                => 'development',
    staging             => 'staging',
    production          => 'production-small',
    'production-small'  => 'production-small',
    'production-medium' => 'production-medium',
);
const my %PROFILES => (
    development => {
        category_cache_ttl_seconds      => 15,
        event_retention_days            => 30,
        local_cache_max_entries         => 256,
        log_level                       => 'debug',
        name                            => 'development',
        notification_retention_days     => 14,
        partition_horizon_months        => 1,
        realtime_processes              => 1,
        requires_glifistore             => 0,
        requires_rotated_session_secret => 0,
        restore_evidence_required       => 0,
        version                         => $PROFILE_VERSION,
        web_processes                   => 1,
        worker_processes                => 1,
    },
    staging => {
        category_cache_ttl_seconds      => 30,
        event_retention_days            => 90,
        local_cache_max_entries         => 512,
        log_level                       => 'info',
        name                            => 'staging',
        notification_retention_days     => 30,
        partition_horizon_months        => 2,
        realtime_processes              => 1,
        requires_glifistore             => 1,
        requires_rotated_session_secret => 1,
        restore_evidence_required       => 1,
        version                         => $PROFILE_VERSION,
        web_processes                   => 2,
        worker_processes                => 1,
    },
    'production-small' => {
        category_cache_ttl_seconds      => 60,
        event_retention_days            => 365,
        local_cache_max_entries         => 2_048,
        log_level                       => 'info',
        name                            => 'production-small',
        notification_retention_days     => 90,
        partition_horizon_months        => 3,
        realtime_processes              => 1,
        requires_glifistore             => 1,
        requires_rotated_session_secret => 1,
        restore_evidence_required       => 1,
        version                         => $PROFILE_VERSION,
        web_processes                   => 4,
        worker_processes                => 2,
    },
    'production-medium' => {
        category_cache_ttl_seconds      => 60,
        event_retention_days            => 730,
        local_cache_max_entries         => 4_096,
        log_level                       => 'info',
        name                            => 'production-medium',
        notification_retention_days     => 180,
        partition_horizon_months        => 6,
        realtime_processes              => 2,
        requires_glifistore             => 1,
        requires_rotated_session_secret => 1,
        restore_evidence_required       => 1,
        version                         => $PROFILE_VERSION,
        web_processes                   => 8,
        worker_processes                => 4,
    },
);

sub names {
    return [ sort keys %PROFILES ];
}

sub name_for_environment {
    my ( undef, $environment ) = @_;

    my $key = $environment || q{};
    if ( !exists $ENV_TO_PROFILE{$key} ) {
        return;
    }

    return $ENV_TO_PROFILE{$key};
}

sub get {
    my ( undef, $name ) = @_;

    if ( !$name || !exists $PROFILES{$name} ) {
        return;
    }

    return { %{ $PROFILES{$name} } };
}

sub evaluate {
    my ( $self, $config ) = @_;

    my $name    = $self->name_for_environment( $config->environment );
    my $profile = $self->get($name);
    if ( !$profile ) {
        return {
            errors  => { environment => 'unknown operational profile' },
            ok      => 0,
            profile => undef,
        };
    }

    return $self->_compare( $profile, $config );
}

sub _compare {
    my ( $self, $profile, $config ) = @_;

    my $errors = {};
    $self->_require_floor(
        $errors,
        {
            actual => $config->web_processes,
            field  => 'web_processes',
            floor  => $profile->{web_processes},
        }
    );
    $self->_require_floor(
        $errors,
        {
            actual => $config->worker_processes,
            field  => 'worker_processes',
            floor  => $profile->{worker_processes},
        }
    );
    $self->_require_floor(
        $errors,
        {
            actual => $config->realtime_processes,
            field  => 'realtime_processes',
            floor  => $profile->{realtime_processes},
        }
    );
    $self->_require_floor(
        $errors,
        {
            actual => $config->local_cache_max_entries,
            field  => 'local_cache_max_entries',
            floor  => $profile->{local_cache_max_entries},
        }
    );
    $self->_require_secret( $errors, $profile, $config );
    $self->_require_glifistore( $errors, $profile, $config );

    return {
        errors  => $errors,
        ok      => keys %{$errors} ? 0 : 1,
        profile => $profile,
    };
}

sub _require_floor {
    my ( undef, $errors, $input ) = @_;

    if ( $input->{actual} < $input->{floor} ) {
        $errors->{ $input->{field} } =
          "$input->{field} is below the operational profile floor";
    }

    return;
}

sub _require_secret {
    my ( undef, $errors, $profile, $config ) = @_;

    if (  !$profile->{requires_rotated_session_secret}
        || $config->session_secret ne $DEVELOPMENT_SECRET )
    {
        return;
    }

    $errors->{session_secret} = 'rotated session secret is required';

    return;
}

sub _require_glifistore {
    my ( undef, $errors, $profile, $config ) = @_;

    if ( !$profile->{requires_glifistore} ) {
        return;
    }

    my $url = $config->glifistore_url;
    if ( defined $url && length $url ) {
        return;
    }

    $errors->{glifistore_url} = 'glifistore_url is required';
    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::Profile - Versioned operational profiles.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = GPForum::Service::Operations::Profile->new->evaluate($config);

=head1 DESCRIPTION

Defines explicit C<development>, C<staging>, C<production-small>, and
C<production-medium> runtime floors plus retention policy. C<production> maps
to C<production-small>. C<test> maps to C<development>. Staging and
production profiles require a GlifiStore URL for the disposable shared L2
cache.

=head1 SUBROUTINES/METHODS

=head2 names

Returns the canonical profile names.

=head2 name_for_environment

Maps a config environment string onto a profile name.

=head2 get

Returns a shallow copy of one named profile.

=head2 evaluate

Compares a config object against the profile for its environment.

=head1 DIAGNOSTICS

Returns C<ok> plus field errors instead of throwing.

=head1 CONFIGURATION AND ENVIRONMENT

Reads process counts, cache size, GlifiStore URL, and session secret from
L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<Const::Fast> and L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Profiles are floors, not exact sizing. Operators may run more processes than
the selected profile.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
