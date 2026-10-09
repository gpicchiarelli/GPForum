# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Migrate;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Config;
use GPForum::Infrastructure::Storage;
use GPForum::Command::PartitionMaintenance;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::Schema;
use GPForum::Service::Admin::Bootstrapper;
use GPForum::Service::Operations::PartitionLifecycle;
use GPForum::Service::Operations::QueryBudget;

our $VERSION = '0.001';

const my $COMMAND => 'gpforum-migrate';
const my %MODE_FOR => (
    '--apply'   => 'apply',
    '--check'   => 'check',
    '--dry-run' => 'plan',
    '--plan'    => 'plan',
);
const my %SWITCH_FOR => (
    '--json'          => [ json       => 1 ],
    '--no-partitions' => [ partitions => 0 ],
    '--quiet'         => [ quiet      => 1 ],
);

# How long the partition step waits for a maintenance run already at work
# (another node's timer, a second deployer) before it skips: long enough for
# a run to finish the window, so the application this deploy starts finds its
# month there.
const my $PARTITION_LOCK_WAIT_MS => 60_000;

# Where an operator goes when the partition step after the migrations fails.
const my $PARTITION_RUNBOOK => 'see docs/ops/partition-maintenance.md and run'
  . ' bin/gpforum-partition-maintenance --plan';

# Where an operator goes when the query budgets could not be brought in line.
const my $BUDGET_RUNBOOK => 'see docs/PERFORMANCE.md#query-budgets and run'
  . ' bin/gpforum-query-budget --sync';

# Environments where a schema change reaches a running service, which reads
# the schema it was started on until it is restarted.
const my $SERVED => qr/\A (?: staging | production )/msx;

# A GPForum::Migration::Runner, for a test; otherwise one is built from the
# GPFORUM_DATABASE_* environment when a mode needs the database.
has runner => undef;    # optional: built when a mode needs the database

# What ensures the partition window once the migrations are in, for a test;
# otherwise a GPForum::Service::Operations::PartitionLifecycle on the
# runner's schema.
has partition_lifecycle => undef;    # optional: the runner's schema's otherwise

# What brings the endpoint query budgets in line with the code once the
# migrations are in, for a test; otherwise a
# GPForum::Service::Operations::QueryBudget on the runner's schema.
has query_budget => undef;    # optional: the runner's schema's otherwise

# Whether the forum has an owner yet, for a test: a code reference given the
# runner, answering true, false or undef for "could not tell". Otherwise
# GPForum::Service::Admin::Bootstrapper asks the runner's schema.
has owner_check => sub { return \&_has_owner; };

# How long the partition step waits for the maintenance lock, in
# milliseconds; a test shortens it.
has partition_lock_wait_ms => sub { return $PARTITION_LOCK_WAIT_MS; };

# The mode without --plan, --apply or --check. bin/gpforum-migrate plans, as
# it always has; `gpforum migrate`, the front door's verb, does the work.
has default_mode => 'plan';

has words => sub { return GPForum::Command::Support::Words->new; };

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, $self->usage_text )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $options = $self->_options(@arguments);
    return GPForum::Command::Usage->error( $options->{error},
        $self->usage_text )
      if defined $options->{error};

    my %work = ( apply => \&_apply, check => \&_check, plan => \&_plan );

    return $work{ $options->{mode} }->( $self, $options );
}

# Every argument is read: `--plan --apply` used to plan and say nothing of
# the --apply, and `--plan --bogus` exited 0. Two modes are misuse rather
# than the last one winning, since one of them changes the schema.
sub _options ( $self, @arguments ) {
    my %options = ( json => 0, partitions => 1, quiet => 0 );
    for my $argument (@arguments) {
        if ( exists $SWITCH_FOR{$argument} ) {
            my ( $name, $value ) = @{ $SWITCH_FOR{$argument} };
            $options{$name} = $value;
            next;
        }
        return {
            error => $self->_said(
                'cli.misuse.unknown_option', { option => $argument }
            )
          }
          if !exists $MODE_FOR{$argument};
        my $mode = $MODE_FOR{$argument};
        return { error => $self->_said('cli.migrate.one_mode') }
          if defined $options{mode} && $options{mode} ne $mode;
        $options{mode} = $mode;
    }
    $options{mode} //= $self->default_mode;
    return { error => $self->_said('cli.migrate.partitions_with_apply') }
      if !$options{partitions} && $options{mode} ne 'apply';

    return \%options;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts. The front
# door's verb applies by default, and says so.
sub usage_text ($invocant) {
    my $applies = ref $invocant && $invocant->default_mode eq 'apply';

    return ( $applies ? _front_door_head() : _entrypoint_head() ) . _body();
}

sub _front_door_head {
    return <<'USAGE';
Usage: gpforum migrate [--plan|--dry-run|--check] [--no-partitions] [--quiet]
                       [--json]

Brings the database up to date, as a fresh install and every deploy need it:
applies the SQL migrations in migrations/ the database has not recorded,
then creates the monthly partitions from this month through the lookahead
that are missing, then makes the endpoint query budgets match the code.

  (no option)      do all of that
  --plan           say which migrations are pending, changing nothing
  --dry-run        the same as --plan
USAGE
}

sub _entrypoint_head {
    return <<'USAGE';
Usage: bin/gpforum-migrate [--plan|--dry-run|--apply|--check] [--no-partitions]
                           [--quiet] [--json]

The alias of gpforum migrate, which applies without --apply. Applies the SQL
migrations in migrations/ the database has not recorded, then creates the
monthly partitions from this month through the lookahead that are missing,
then makes the endpoint query budgets match the code.

  --plan           say which migrations are pending, changing nothing
                   (default)
  --dry-run        the same as --plan
  --apply          apply them, then the partitions and the budgets
USAGE
}

sub _body {
    return <<'USAGE';
  --check          report the ones not applied yet, and fail if there are any
                   or if an applied file changed since
  --no-partitions  leave the partition window alone
  --quiet          print nothing when there is no failure, for scripts
  --json           one JSON object on stdout instead of sentences
  --help           show this help

Each migration is recorded with its checksum in schema_versions, under an
advisory lock, so two deployers cannot apply the same one at once.

Exit status: 0 success; 1 a migration failed, the partition window or the
query budgets could not be brought up to date once the migrations were in
(see docs/ops/partition-maintenance.md), or --check found the schema behind;
78 settings it cannot use; 2 usage error.
USAGE
}

# What is pending, which needs the database: listing migrations/ alone
# could not say. migrations/ is read from the working directory first, so a
# run from anywhere else fails on that, without a connection: there, the
# plan's croak escaped uncaught, and Perl took the exit status from $!: 2,
# the missing directory's ENOENT, which a deploy script reads as misuse.
sub _plan ( $self, $options ) {
    my ( $plan, $pending );
    try {
        $plan    = GPForum::Migration::Plan->new->summary;
        $pending = $self->_runner(0)->pending;
    }
    catch ($error) {
        return GPForum::Command::Usage->failure( $error,
            _json_failure( $options, { migrations => [], mode => 'plan' } ) );
    };

    if ( $options->{json} ) {
        return _json(
            {
                migrations => $plan,
                mode       => 'plan',
                pending    => $pending,
                status     => 'ok',
            }
        );
    }
    return 0 if $options->{quiet};

    if ( !@{$pending} ) {
        $self->_say(
            $self->_said(
                'cli.migrate.current', { version => _latest($plan) }
              )
              . q{.}
        );
        return 0;
    }
    $self->_say( $self->_counted( 'cli.migrate.pending', $pending ) . q{:} );
    for my $migration ( @{$pending} ) {
        $self->_say("  $migration->{version} $migration->{description}");
    }
    $self->_next( $self->_said('cli.migrate.next_apply') );

    return 0;
}

# A run that fails once it has started has no "applied": each migration
# commits as it goes, so the ones before the failure are in the schema, and
# the runner's error does not say which. An empty list said none were, to a
# deploy deciding whether the old code still matches the database; --check
# answers what is left. A database never reached applied nothing, and says so.
sub _apply ( $self, $options ) {
    my ( $runner, $result );
    try {
        $runner = $self->_runner(1);
    }
    catch ($error) {
        return GPForum::Command::Usage->failure( $error,
            _json_failure( $options, { applied => [], mode => 'apply' } ) );
    };
    try {
        $result = $runner->apply_pending;
    }
    catch ($error) {
        return GPForum::Command::Usage->failure( $error,
            _json_failure( $options, { mode => 'apply' } ) );
    };

    my %document = (
        applied => [ map { _applied($_) } @{$result} ],
        mode    => 'apply',
    );
    my $window = $options->{partitions} ? $self->_ensure_window($runner) : {};
    if ( $window->{document} ) {
        $document{partitions} = $window->{document};
    }
    my $budgets = defined $window->{error} ? {} : $self->_sync_budgets($runner);
    if ( $budgets->{document} ) {
        $document{budgets} = $budgets->{document};
    }

    my $problem = $window->{error} // $budgets->{error};
    if ( defined $problem ) {
        if ( !$options->{json} && !$options->{quiet} ) {
            $self->_say( $self->summary( $result, \%document ) . q{.} );
        }
        return GPForum::Command::Usage->failure( $problem,
            _json_failure( $options, \%document ) );
    }
    return _json( { %document, status => 'ok' } ) if $options->{json};
    return 0                                      if $options->{quiet};

    $self->_say( $self->summary( $result, \%document ) . q{.} );
    my $next = $self->_next_after_apply( $runner, $result );
    if ( defined $next ) {
        $self->_next($next);
    }

    return 0;
}

# One line for the whole run: the migrations applied, or that the schema was
# current, then the partitions and budgets it changed. A line per migration,
# each with its checksum, was 51 lines on a fresh install; nothing at all
# when the schema was current left an operator wondering whether it ran.
# Public for gpforum setup, which says the same line from --json's document.
sub summary ( $self, $result, $document ) {
    my @parts =
      @{$result}
      ? ( $self->_counted( 'cli.migrate.applied', $result ) )
      : (
        $self->_said(
            'cli.migrate.current',
            { version => _latest( GPForum::Migration::Plan->new->summary ) }
        )
      );
    my $created =
      $document->{partitions} ? $document->{partitions}{created} : [];
    if ( @{$created} ) {
        push @parts, $self->_counted( 'cli.migrate.partitions', $created );
    }
    my $budgets = $document->{budgets};
    if ( $budgets && $budgets->{written} + @{ $budgets->{removed} } ) {
        push @parts,
          $self->_said( 'cli.migrate.budgets',
            { count => $budgets->{written} + @{ $budgets->{removed} } } );
    }

    return join q{; }, @parts;
}

# The step after the migrations: the forum's owner on an install that has
# none; else, after a change, a restart for a service that runs the old
# schema until it is restarted, or a start on a development checkout.
sub _next_after_apply ( $self, $runner, $result ) {
    my $owned = $self->owner_check->($runner);
    return $self->_said('cli.migrate.next_owner') if defined $owned && !$owned;
    return undef                                  if !@{$result};

    my $environment = $ENV{GPFORUM_ENV} // 'development';
    return $self->_said('cli.migrate.next_start') if $environment !~ $SERVED;

    my $restart =
      GPForum::Command::Support::ServiceEnvironment->new->restart_command;
    return
      defined $restart
      ? $self->_said( 'cli.migrate.next_restart', { restart => $restart } )
      : undef;
}

sub _has_owner ($runner) {
    return undef if !$runner->can('schema') || !$runner->schema;

    my $owned;
    try {
        $owned =
          GPForum::Service::Admin::Bootstrapper->new(
            schema => $runner->schema )->has_owner;
    }
    catch ($error) {
        $owned = undef;
    };

    return $owned;
}

# ADR 0113: every deploy, and a fresh install before its first write, gets
# the current month and the lookahead. The migrations have committed by now,
# so a failure here cannot undo them; it fails the command all the same,
# loudly, because rows written past the window land in the DEFAULT partition
# and that is only undone by hand. Another run holding the maintenance lock
# is waited for, a minute at most, and then no failure: that run is doing
# this work.
sub _ensure_window ( $self, $runner ) {
    my $result;
    try {
        $result =
          $self->_lifecycle_for($runner)->ensure_partitions( { apply => 1 } );
    }
    catch ($error) {
        return {
                error => 'migrations applied, but the partition window could'
              . ' not be ensured: '
              . GPForum::Command::Usage->trimmed($error) . q{; }
              . $PARTITION_RUNBOOK, };
    };

    my %window = ( document =>
          GPForum::Command::PartitionMaintenance->result_document($result) );
    if ( !$result->{ok} ) {
        $window{error} = _window_problem($result);
    }

    return \%window;
}

sub _window_problem ($result) {
    my @problems =
      map { "$_->{partition_name}: " . ( $_->{message} // $_->{error} ) }
      @{ $result->{conflicts} }, @{ $result->{errors} };

    return
        'migrations applied, but the partition window is incomplete: '
      . scalar( @{ $result->{conflicts} } )
      . ' conflict(s), '
      . scalar( @{ $result->{errors} } )
      . ' error(s) ('
      . join( q{; }, @problems ) . '); '
      . $PARTITION_RUNBOOK;
}

# The endpoint query budgets the readiness report compares with the code.
# A fresh install that migrated without syncing them answered /health/ready
# with 503 until an operator found the runbook; a deploy that changed the
# catalog drifted until someone remembered. A sync writes only the rows that
# differ, so a current install writes nothing.
sub _sync_budgets ( $self, $runner ) {
    my $result;
    try {
        $result = (
            $self->query_budget
              // GPForum::Service::Operations::QueryBudget->new(
                schema => $runner->schema
              )
        )->sync_schema( $runner->schema );
    }
    catch ($error) {
        return {
                error => 'migrations applied, but the query budgets could not'
              . ' be synced: '
              . GPForum::Command::Usage->trimmed($error) . q{; }
              . $BUDGET_RUNBOOK, };
    };

    return {
        document => {
            removed => $result->{removed} // [],
            status  => 'ok',
            synced  => $result->{synced}  // 0,
            written => $result->{written} // 0,
        }
    };
}

# The migrations ran with statement_timeout lifted; the partition step gets
# the configured one back, since an ATTACH scans the whole DEFAULT partition
# while every unpruned read of the table waits for it.
sub _lifecycle_for ( $self, $runner ) {
    return $self->partition_lifecycle if $self->partition_lifecycle;

    return GPForum::Service::Operations::PartitionLifecycle->new(
        lock_wait_ms         => $self->partition_lock_wait_ms,
        schema               => $runner->schema,
        statement_timeout_ms =>
          GPForum::Config->from_environment->database_statement_timeout_ms,
    );
}

# Whether this database is where the code expects it: nothing pending, and no
# applied file edited since -- the question a deploy asks before it switches
# the code over.
sub _check ( $self, $options ) {
    my $pending;
    try {
        my $runner = $self->_runner(0);
        $runner->verify_applied;
        $pending = $runner->pending;
    }
    catch ($error) {
        return GPForum::Command::Usage->failure( $error,
            _json_failure( $options, { mode => 'check', pending => [] } ) );
    };

    my $status = @{$pending} ? 'fail' : 'ok';
    if ( $options->{json} ) {
        _json( { mode => 'check', pending => $pending, status => $status } );
    }
    elsif ( $self->default_mode eq 'apply' ) {
        if ( !$options->{quiet} || $status ne 'ok' ) {
            $self->_say_check($pending);
        }
    }
    elsif ( !$options->{quiet} || $status ne 'ok' ) {
        _print_check( $pending, $status );
    }

    return $status eq 'ok' ? 0 : $GPForum::Command::Usage::EXIT_FAILURE;
}

# The check as the front door's verb says it, in the words the plan uses:
# the schema current, or how many migrations wait and the command that
# applies them. bin/gpforum-migrate --check keeps its status= line.
sub _say_check ( $self, $pending ) {
    if ( !@{$pending} ) {
        $self->_say(
            "\N{CHECK MARK} "
              . $self->_said(
                'cli.migrate.current',
                {
                    version => _latest( GPForum::Migration::Plan->new->summary )
                }
              )
              . q{.}
        );
        return;
    }

    $self->_say( "\N{BALLOT X} "
          . $self->_counted( 'cli.migrate.pending', $pending )
          . q{.} );
    $self->_next( $self->_said('cli.migrate.next_apply') );

    return;
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

sub _latest ($plan) {
    return @{$plan} ? $plan->[-1]{version} : q{-};
}

# A sentence counted over a list: the key's _one form for one item, its
# _many form otherwise, given the count and the first and last versions.
sub _counted ( $self, $key, $items ) {
    my $count      = scalar @{$items};
    my %parameters = (
        count       => $count,
        description => $items->[0]{description} // q{},
        first       => $items->[0]{version}     // q{},
        last        => $items->[-1]{version}    // q{},
        version     => $items->[0]{version}     // q{},
    );

    return $self->_said( $key . ( $count == 1 ? '_one' : '_many' ),
        \%parameters );
}

sub _said ( $self, $key, $parameters = {} ) {
    return $self->words->text( $key, $parameters );
}

sub _next ( $self, $step ) {
    $self->_say( $self->_said( 'cli.next', { step => $step } ) );

    return;
}

# The next step reads the file this run read, when that is not the host's
# own: gpforum admin create, after gpforum --env-file FILE migrate, makes
# the owner of the database FILE names.
sub _say ( $self, $line ) {
    my $read = GPForum::Command::Support::ServiceEnvironment->as_read($line);
    print encode( 'UTF-8', "$read\n" )
      or croak 'failed to write migration result';

    return;
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

    # Applying allows a migration statement as long as it takes: an index
    # build must not be cut off by the statement timeout the forum runs under.
    if ($for_apply) {
        my $dbh = GPForum::Infrastructure::Storage->dbh_of($schema);
        if ($dbh) {
            $dbh->do('SET statement_timeout = 0');
        }
    }

    return GPForum::Migration::Runner->new( schema => $schema );
}

1;

__END__

=head1 NAME

GPForum::Command::Migrate - Brings the database up to date.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # gpforum migrate
    exit GPForum::Command::Migrate->new( default_mode => 'apply' )->run(@ARGV);

    # bin/gpforum-migrate, its alias
    exit GPForum::Command::Migrate->new->run(@ARGV);

=head1 DESCRIPTION

C<gpforum migrate> and its alias C<bin/gpforum-migrate>: the SQL migrations,
then the partition window, then the endpoint query budgets, so a fresh
install and every deploy end with a schema the code and the readiness report
agree with.

=head1 SUBROUTINES/METHODS

=head2 run

Runs C<--plan> (or C<--dry-run>), C<--apply> or C<--check> -- or, without
one, C<default_mode> -- as sentences or, with C<--json>, as one JSON object.
Returns 0; 1 when a migration failed, the window or the budgets could not be
brought up to date, or C<--check> found the schema behind or an applied file
changed; 78 when the settings cannot be used; and 2 on misuse.

C<--plan> connects and lists the pending migrations, then C<Next: gpforum
migrate>; with none pending it says C<Schema is current (NNN).> Its
document carries C<migrations> (every file in F<migrations/>) and
C<pending>.

C<--apply> applies the pending migrations, then ensures the partition window
as C<gpforum partitions --apply> does, with the default lookahead (ADR 0113),
then syncs the endpoint query budgets as C<gpforum budgets --sync> does. It
says it all in one line -- C<Applied 51 migrations, 001 to 051; created 26
monthly partitions; synced 25 query budgets.>, or C<Schema is current
(051).> when there was nothing to do -- and then the next step: making the
forum's owner when it has none, restarting the service after a change in
staging and production, or starting it on a development checkout.
C<--quiet> prints nothing unless something failed. With C<--json> the
document carries C<applied>, C<partitions> in the shape
L<GPForum::Command::PartitionMaintenance/result_document> gives, and
C<budgets> (C<synced>, C<written>, C<removed>). A conflict or error in the
window, or a sync that fails, returns 1 with a message naming the runbook;
the migrations stay applied and C<applied> still lists them. Another run
holding the maintenance lock is waited for, up to C<partition_lock_wait_ms>
(a minute); past that the window is reported as C<skipped>, which is no
failure. C<--no-partitions> leaves the window alone and the document
without C<partitions>.

=head2 summary

Takes the migrations applied (each with its C<version> and C<description>)
and the run's document (its C<partitions> and C<budgets>, as C<--json>
prints them) and returns the run's one line, in the operator's language,
without its full stop.

=head2 usage_text

The text C<--help> prints: the front door's when C<default_mode> is
C<apply>, the alias's otherwise.

=head1 DIAGNOSTICS

A failure prints its reason to standard error and returns 1, or 78 for
settings it cannot use; misuse prints what was wrong and the usage to
standard error and returns 2.

=head1 CONFIGURATION AND ENVIRONMENT

Every mode reads the C<GPFORUM_*> database settings through
L<GPForum::Config>. C<--apply> then sets C<statement_timeout = 0> so
migration DDL is not capped at the web session budget.
C<idle_in_transaction_session_timeout> and C<lock_timeout> stay on the
session for the migrations. The partition step after them sets
C<statement_timeout> back to the configured
C<GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS> and C<lock_timeout> to the
lifecycle's half second per attempt. C<GPFORUM_ENV> chooses the next step
it names. Its sentences follow C<LC_ALL>, C<LC_MESSAGES> or C<LANG>
(L<GPForum::Command::Support::Words>).

=head1 DEPENDENCIES

Uses L<GPForum::Migration::Plan>, L<GPForum::Migration::Runner>,
L<GPForum::Schema>, L<GPForum::Service::Operations::PartitionLifecycle>,
L<GPForum::Service::Operations::QueryBudget>,
L<GPForum::Service::Admin::Bootstrapper> and
L<GPForum::Command::Support::Words>.

=head1 INCOMPATIBILITIES

Before the front door, C<--apply> printed a line per migration with its
checksum and nothing when the schema was current; scripts that checked for
silence pass C<--quiet>.

=head1 BUGS AND LIMITATIONS

C<--check> reports a changed file by the reason
L<GPForum::Migration::Runner> gives, not as a list of its own. Its lines keep
their C<key=value> form, which deploy scripts read.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
