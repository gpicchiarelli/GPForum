# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Migrate;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base, -signatures;

use GPForum::Config;
use GPForum::Command::Usage;
use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::Schema;

our $VERSION = '0.001';

sub run ( $self, @arguments ) {
    my $command = shift @arguments;
    if ( !defined $command ) {
        $command = '--plan';
    }

    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if $command eq '--help' || $command eq '-h';

    return GPForum::Command::Usage->error( "unknown option $command", _usage() )
      if $command ne '--plan' && $command ne '--apply';

    return $self->_print_plan
      if $command eq '--plan';

    return $self->_apply;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-migrate [--plan|--apply]

Applies the SQL migrations in migrations/ in order, recording each one and its
checksum in schema_migrations. Runs under an advisory lock, so two deployers
cannot apply the same migration at once.

  --plan   list the migrations that would be applied (default)
  --apply  apply them
  --help   show this help

Exit status: 0 success, 1 a migration failed, 2 usage error.
USAGE
}

sub _print_plan ($self) {
    my $plan = GPForum::Migration::Plan->new->summary;

    for my $migration ( @{$plan} ) {
        print
          "$migration->{version} $migration->{description} $migration->{file}\n"
          or croak 'failed to write migration plan';
    }

    return 0;
}

sub _apply ($self) {
    my $config = GPForum::Config->from_environment;
    my $schema = GPForum::Schema->connect_from_config($config);
    $self->_allow_long_migration_statements($schema);
    my $runner = GPForum::Migration::Runner->new( schema => $schema );
    my $result = $runner->apply_pending;

    for my $migration ( @{$result} ) {
        print
"applied $migration->{version} $migration->{description} $migration->{checksum}\n"
          or croak 'failed to write migration apply result';
    }

    return 0;
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

Runs C<--plan> or C<--apply>.

=head1 DIAGNOSTICS

Throws exceptions for unsupported command arguments and write failures.

=head1 CONFIGURATION AND ENVIRONMENT

C<--apply> reads C<GPFORUM_*> database settings through L<GPForum::Config>
and then sets C<statement_timeout = 0> so migration DDL is not capped at the
web session budget. C<idle_in_transaction_session_timeout> and
C<lock_timeout> stay on the session.

=head1 DEPENDENCIES

Uses L<GPForum::Migration::Plan>, L<GPForum::Migration::Runner>, and
L<GPForum::Schema>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Only migration planning and applying are implemented.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
