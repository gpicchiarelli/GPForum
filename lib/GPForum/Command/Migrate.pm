# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Migrate;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Config;
use GPForum::Command::Usage;
use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::Schema;

our $VERSION = '0.001';

const my $COMMAND => 'gpforum-migrate';
const my %MODE_FOR => (
    '--apply' => 'apply',
    '--check' => 'check',
    '--plan'  => 'plan',
);

# A GPForum::Migration::Runner, for a test; otherwise one is built from the
# GPFORUM_DATABASE_* environment when a mode needs the database.
has runner => undef;

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $options = _options(@arguments);
    return GPForum::Command::Usage->error( $options->{error}, _usage() )
      if defined $options->{error};

    my %work = ( apply => \&_apply, check => \&_check, plan => \&_plan );

    return $work{ $options->{mode} }->( $self, $options );
}

# Every argument is read: `--plan --apply` used to plan and say nothing of
# the --apply, and `--plan --bogus` exited 0. Two modes are misuse rather
# than the last one winning, since one of them changes the schema.
sub _options (@arguments) {
    my %options = ( json => 0 );
    for my $argument (@arguments) {
        if ( $argument eq '--json' ) {
            $options{json} = 1;
            next;
        }
        return { error => "unknown option $argument" }
          if !exists $MODE_FOR{$argument};
        my $mode = $MODE_FOR{$argument};
        return { error => 'choose one of --plan, --apply and --check' }
          if defined $options{mode} && $options{mode} ne $mode;
        $options{mode} = $mode;
    }
    $options{mode} //= 'plan';

    return \%options;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-migrate [--plan|--apply|--check] [--json]

Applies the SQL migrations in migrations/ in order, recording each one and its
checksum in schema_versions. Runs under an advisory lock, so two deployers
cannot apply the same migration at once.

  --plan   list the migrations in migrations/, without the database (default)
  --apply  apply the ones the database has not recorded
  --check  report the ones not applied yet, and fail if there are any or if
           an applied file changed since
  --json   one JSON object on stdout instead of lines
  --help   show this help

Exit status: 0 success, 1 a migration failed or --check found the schema
behind, 2 usage error.
USAGE
}

# migrations/ is read from the working directory. Run from anywhere else, the
# plan's croak escaped uncaught, and Perl took the exit status from $!: 2, the
# missing directory's ENOENT, which a deploy script reads as misuse.
sub _plan ( $self, $options ) {
    my $plan = eval { return GPForum::Migration::Plan->new->summary; };
    if ( !$plan ) {
        return GPForum::Command::Usage->failure( $EVAL_ERROR,
            _json_failure( $options, { migrations => [], mode => 'plan' } ) );
    }
    if ( $options->{json} ) {
        return _json( { migrations => $plan, mode => 'plan', status => 'ok' } );
    }

    for my $migration ( @{$plan} ) {
        print
          "$migration->{version} $migration->{description} $migration->{file}\n"
          or croak 'failed to write migration plan';
    }

    return 0;
}

# A run that fails once it has started has no "applied": each migration
# commits as it goes, so the ones before the failure are in the schema, and
# the runner's error does not say which. An empty list said none were, to a
# deploy deciding whether the old code still matches the database; --check
# answers what is left. A database never reached applied nothing, and says so.
sub _apply ( $self, $options ) {
    my $runner = eval { return $self->_runner(1); };
    if ( !$runner ) {
        return GPForum::Command::Usage->failure( $EVAL_ERROR,
            _json_failure( $options, { applied => [], mode => 'apply' } ) );
    }
    my $result = eval { return $runner->apply_pending; };
    if ( !$result ) {
        return GPForum::Command::Usage->failure( $EVAL_ERROR,
            _json_failure( $options, { mode => 'apply' } ) );
    }
    if ( $options->{json} ) {
        return _json(
            {
                applied => [ map { _applied($_) } @{$result} ],
                mode    => 'apply',
                status  => 'ok',
            }
        );
    }

    for my $migration ( @{$result} ) {
        print
"applied $migration->{version} $migration->{description} $migration->{checksum}\n"
          or croak 'failed to write migration apply result';
    }

    return 0;
}

# Whether this database is where the code expects it: nothing pending, and no
# applied file edited since -- the question a deploy asks before it switches
# the code over, and that --plan cannot answer without the database.
sub _check ( $self, $options ) {
    my $pending = eval {
        my $runner = $self->_runner(0);
        $runner->verify_applied;
        return $runner->pending;
    };
    if ( !$pending ) {
        return GPForum::Command::Usage->failure( $EVAL_ERROR,
            _json_failure( $options, { mode => 'check', pending => [] } ) );
    }
    my $status = @{$pending} ? 'fail' : 'ok';
    if ( $options->{json} ) {
        _json( { mode => 'check', pending => $pending, status => $status } );
    }
    else {
        _print_check( $pending, $status );
    }

    return $status eq 'ok' ? 0 : $GPForum::Command::Usage::EXIT_FAILURE;
}

sub _print_check ( $pending, $status ) {
    for my $migration ( @{$pending} ) {
        print
"pending $migration->{version} $migration->{description} $migration->{file}\n"
          or croak 'failed to write migration check';
    }
    print 'migrate check status=' . $status . ' pending=' . @{$pending} . "\n"
      or croak 'failed to write migration check';

    return;
}

sub _applied ($migration) {
    return { map { $_ => $migration->{$_} }
          qw(checksum description execution_time_ms version) };
}

sub _json ($document) {
    GPForum::Command::Usage->json( \*STDOUT,
        { command => $COMMAND, %{$document} } );

    return $document->{status} eq 'ok'
      ? 0
      : $GPForum::Command::Usage::EXIT_FAILURE;
}

sub _json_failure ( $options, $document ) {
    return if !$options->{json};

    return ( \*STDOUT, { command => $COMMAND, %{$document} } );
}

# A failure to reach the database is a failure, not a schema with every
# migration pending: Runner reads what was applied leniently, so that a
# database without schema_versions yet reads as empty.
sub _runner ( $self, $for_apply ) {
    return $self->runner if $self->runner;

    my $config = GPForum::Config->from_environment;
    my $schema = GPForum::Schema->connect_from_config($config);
    $schema->storage->ensure_connected;
    if ($for_apply) {
        $self->_allow_long_migration_statements($schema);
    }

    return GPForum::Migration::Runner->new( schema => $schema );
}

sub _allow_long_migration_statements ( $self, $schema ) {
    my $dbh = $self->_schema_dbh($schema);
    if ( !$dbh ) {
        return;
    }

    $dbh->do('SET statement_timeout = 0');

    return;
}

sub _schema_dbh ( $self, $schema ) {
    my $storage = eval { return $schema->storage; };
    if ( !$storage || !$storage->can('dbh') ) {
        my $undefined;
        return $undefined;
    }

    return eval { return $storage->dbh; };
}

1;

__END__

=head1 NAME

GPForum::Command::Migrate - Command-line migration entry point.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::Migrate->new->run(@ARGV);

=head1 DESCRIPTION

Provides the C<bin/gpforum-migrate> command implementation while keeping the
script itself small enough for strict Perl::Critic gates.

=head1 SUBROUTINES/METHODS

=head2 run

Runs C<--plan>, C<--apply> or C<--check>, as lines or, with C<--json>, as
one JSON object. Returns 0, 1 when a migration failed or C<--check> found the
schema behind or an applied file changed, and 2 on misuse.

=head2 usage_text

The text C<--help> prints.

=head1 DIAGNOSTICS

A failure prints its reason to standard error and returns 1; misuse prints
the usage to standard error and returns 2.

=head1 CONFIGURATION AND ENVIRONMENT

C<--apply> and C<--check> read C<GPFORUM_*> database settings through L<GPForum::Config>
and then sets C<statement_timeout = 0> so migration DDL is not capped at the
web session budget. C<idle_in_transaction_session_timeout> and
C<lock_timeout> stay on the session.

=head1 DEPENDENCIES

Uses L<GPForum::Migration::Plan>, L<GPForum::Migration::Runner>, and
L<GPForum::Schema>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

C<--check> reports a changed file by the reason
L<GPForum::Migration::Runner> gives, not as a list of its own.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
