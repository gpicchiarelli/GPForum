package GPForum::Command::Migrate;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

use GPForum::Config;
use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::Schema;

our $VERSION = '0.001';

sub run {
    my ( $self, @arguments ) = @_;

    my $command = shift @arguments;
    if ( !defined $command ) {
        $command = '--plan';
    }

    croak "Usage: bin/gpforum-migrate --plan|--apply\n"
      if $command ne '--plan' && $command ne '--apply';

    return $self->_print_plan
      if $command eq '--plan';

    return $self->_apply;
}

sub _print_plan {
    my ($self) = @_;

    my $plan = GPForum::Migration::Plan->new->summary;

    for my $migration ( @{$plan} ) {
        print
          "$migration->{version} $migration->{description} $migration->{file}\n"
          or croak 'failed to write migration plan';
    }

    return 0;
}

sub _apply {
    my ($self) = @_;

    my $config = GPForum::Config->from_environment;
    my $schema = GPForum::Schema->connect_from_config($config);
    my $runner = GPForum::Migration::Runner->new( schema => $schema );
    my $result = $runner->apply_pending;

    for my $migration ( @{$result} ) {
        print
"applied $migration->{version} $migration->{description} $migration->{checksum}\n"
          or croak 'failed to write migration apply result';
    }

    return 0;
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

C<--apply> reads C<GPFORUM_*> database settings through L<GPForum::Config>.

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
