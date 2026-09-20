package GPForum::Command::StagingDrill;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Service::Operations::StagingDrill;

our $VERSION = '0.001';

const my $DEFAULT_SEED_PROFILE => 'small';
const my $EXIT_USAGE           => 2;
const my %SEED_PROFILES => map { $_ => 1 } qw(small medium hot-thread none);
const my %FLAG_OPTIONS => (
    '--help'              => 'help',
    '--json'              => 'format_json',
    '--human'             => 'format_human',
    '--skip-upgrade'      => 'skip_upgrade',
    '--skip-dump-restore' => 'skip_dump_restore',
    '--keep-databases'    => 'keep_databases',
);
const my %VALUE_OPTIONS => (
    '--database'     => 'database_prefix',
    '--seed-profile' => 'seed_profile',
);

has drill => undef;

sub run {
    my ( $self, @arguments ) = @_;

    my $options = eval { return _options(@arguments) };
    if ( !$options ) {
        print {*STDERR} _trim($EVAL_ERROR)
          or croak 'failed to write staging drill usage error';
        return $EXIT_USAGE;
    }
    return _print_usage() if $options->{help};

    my $service  = $self->_service;
    my $evidence = $service->run($options);
    print $service->format_evidence( $evidence, $options->{format} )
      or croak 'failed to write staging drill evidence';

    return $service->exit_status($evidence);
}

sub _service {
    my ($self) = @_;

    return $self->drill if $self->drill;

    return GPForum::Service::Operations::StagingDrill->new;
}

sub _options {
    my (@arguments) = @_;

    my %options = (
        format            => 'json',
        seed_profile      => $DEFAULT_SEED_PROFILE,
        skip_upgrade      => 0,
        skip_dump_restore => 0,
        keep_databases    => 0,
        help              => 0,
        database_prefix   => undef,
    );

    while (@arguments) {
        _apply_option( \%options, shift @arguments, \@arguments );
    }

    return \%options;
}

sub _apply_option {
    my ( $options, $argument, $arguments ) = @_;

    if ( exists $FLAG_OPTIONS{$argument} ) {
        _set_flag( $options, $FLAG_OPTIONS{$argument} );
        return;
    }
    if ( exists $VALUE_OPTIONS{$argument} ) {
        _set_value( $options, $VALUE_OPTIONS{$argument}, $arguments );
        return;
    }

    croak "Unknown option: $argument\n" . _usage();
}

sub _flag_handlers {
    return {
        help              => \&_set_help,
        format_json       => \&_set_format_json,
        format_human      => \&_set_format_human,
        skip_upgrade      => \&_set_skip_upgrade,
        skip_dump_restore => \&_set_skip_dump,
        keep_databases    => \&_set_keep_databases,
    };
}

sub _set_flag {
    my ( $options, $name ) = @_;

    my $handler = _flag_handlers()->{$name};
    croak _usage() if !$handler;
    $handler->($options);

    return;
}

sub _set_help {
    my ($options) = @_;
    $options->{help} = 1;
    return;
}

sub _set_format_json {
    my ($options) = @_;
    $options->{format} = 'json';
    return;
}

sub _set_format_human {
    my ($options) = @_;
    $options->{format} = 'human';
    return;
}

sub _set_skip_upgrade {
    my ($options) = @_;
    $options->{skip_upgrade} = 1;
    return;
}

sub _set_skip_dump {
    my ($options) = @_;
    $options->{skip_dump_restore} = 1;
    return;
}

sub _set_keep_databases {
    my ($options) = @_;
    $options->{keep_databases} = 1;
    return;
}

sub _value_handlers {
    return {
        database_prefix => \&_set_database_prefix,
        seed_profile    => \&_set_seed_profile,
    };
}

sub _set_value {
    my ( $options, $name, $arguments ) = @_;

    my $value = shift @{$arguments};
    croak _usage() if !_has_text($value) || substr( $value, 0, 1 ) eq q{-};

    my $handler = _value_handlers()->{$name};
    croak _usage() if !$handler;
    $handler->( $options, $value );

    return;
}

sub _set_database_prefix {
    my ( $options, $value ) = @_;
    $options->{database_prefix} = $value;
    return;
}

sub _set_seed_profile {
    my ( $options, $value ) = @_;

    croak "Unsupported seed profile: $value\n" . _usage()
      if !_seed_profile_allowed($value);
    $options->{seed_profile} = $value;

    return;
}

sub _seed_profile_allowed {
    my ($value) = @_;

    for my $allowed ( keys %SEED_PROFILES ) {
        return 1 if $allowed eq $value;
    }

    return 0;
}

sub _print_usage {
    print _usage() or croak 'failed to write usage';

    return 0;
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-staging-drill [options]

Requires GPFORUM_DATABASE_DSN (and user/password env as for other tools).
Creates throwaway databases, migrates, optionally seeds, dumps/restores,
prints evidence, then drops throwaways.

  --json                 evidence as JSON (default)
  --human                short plain-text evidence
  --database PREFIX      throwaway name prefix (default gpforum_drill_<pid>_<time>)
  --seed-profile NAME    small|medium|hot-thread|none (default small)
  --skip-upgrade         skip upgrade-from-previous migration path
  --skip-dump-restore    skip pg_dump/pg_restore round-trip
  --keep-databases       leave throwaway databases after the run
  --help                 show this help

Attachment blobs under var/attachments are not covered by dump/restore.
USAGE
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
}

sub _trim {
    my ($error) = @_;

    $error = "$error";
    $error =~ s/\s+\z//msx;

    return "$error\n";
}

1;

__END__

=head1 NAME

GPForum::Command::StagingDrill - Operator CLI for migrate/dump/restore drills.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::StagingDrill->new->run(@ARGV);

=head1 DESCRIPTION

Thin command entry point for L<GPForum::Service::Operations::StagingDrill>.

=head1 SUBROUTINES/METHODS

=head2 run

Parses options, runs the drill, prints evidence, and returns an exit status.

=head1 DIAGNOSTICS

Unknown options and unsupported seed profiles croak with usage text. Missing
database environment or drill failures produce non-zero exit status after
evidence is printed.

=head1 CONFIGURATION AND ENVIRONMENT

See L<GPForum::Service::Operations::StagingDrill>.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::StagingDrill>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Does not rehearse full nginx/systemd deployment.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
