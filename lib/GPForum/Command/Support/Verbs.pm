# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Support::Verbs;

use Const::Fast;
use List::Util qw(first);
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# What an operator types after `gpforum`, by what they are doing: setting a
# forum up, running it, checking it, maintaining it, and the rest -- the
# benchmarks, seeds, drills and evidence a release needs and an operator
# rarely does. Each verb names the command that does the work (a
# GPForum::CLI adapter) and the bin/ entrypoint that did it before the front
# door, which stays as its alias. The front door's help is drawn from this
# table, and a help text that names a bin/ entrypoint is shown with the verb
# instead when the operator came in through the front door.
const my @VERBS => (
    [qw(setup setup setup)],
    [qw(migrate setup migrate gpforum-migrate)],
    [ 'admin',  'setup', 'admin',  'gpforum-admin-bootstrap', 'admin grant' ],
    [ 'secret', 'setup', 'secret', undef ],
    [ 'start',  'run',   'start',  undef, undef, 'application' ],
    [
        'outbox',          'run',
        'outbox_dispatch', 'gpforum-outbox-dispatch',
        undef,             'application'
    ],
    [
        'scheduled-jobs', 'run',
        'scheduled_jobs', 'gpforum-scheduled-jobs',
        undef,            'application'
    ],
    [qw(service setup service)],
    [ qw(doctor check doctor), undef ],
    [ qw(status check status), undef ],
    [qw(mail-check check mail_check gpforum-mail-check)],
    [qw(antivirus-check check antivirus_check gpforum-antivirus-check)],
    [qw(platform-check check platform_check gpforum-platform-check)],
    [qw(os-preflight check os_preflight gpforum-os-preflight)],
    [qw(search-rebuild maintain search_rebuild gpforum-search-rebuild)],
    [qw(dead-letters maintain dead_letter_replay gpforum-dead-letter-replay)],
    [
        qw(partitions maintain partition_maintenance
          gpforum-partition-maintenance)
    ],
    [qw(budgets maintain query_budget gpforum-query-budget)],
    [qw(backup maintain backup)],
    [qw(restore maintain restore)],
    [qw(upgrade maintain upgrade)],
    [qw(benchmark more benchmark gpforum-benchmark)],
    [qw(hypnotoad-benchmark more hypnotoad_benchmark gpforum-bench-hypnotoad)],
    [
        qw(hypnotoad-scaling more hypnotoad_scaling
          gpforum-bench-hypnotoad-scaling)
    ],
    [qw(performance-seed more performance_seed gpforum-seed-performance-data)],
    [qw(stress-load more stress_load gpforum-stress-load)],
    [
        qw(query-plan-evidence more query_plan_evidence gpforum-query-plan-evidence)
    ],
    [qw(staging-drill more staging_drill gpforum-staging-drill)],
    [
        qw(staging-drill-attachments more staging_drill_attachments
          gpforum-staging-drill-attachments)
    ],
    [
        qw(staging-host-verify more staging_host_verify gpforum-staging-host-verify)
    ],
    [qw(evidence-meta more evidence_meta gpforum-evidence-meta)],
    [qw(evidence-validate more evidence_validate gpforum-evidence-validate)],
    [qw(dead-letter-check more dead_letter_check gpforum-dead-letter-check)],
    [
        qw(mail-lifecycle-check more mail_lifecycle_check
          gpforum-mail-lifecycle-check)
    ],
);

# bin/ entrypoints that run a verb's command under another name.
const my %OTHER_ENTRYPOINT =>
  ( 'gpforum-seed-benchmark' => 'performance-seed' );

# The groups, in the order the help shows them. "more" is shown by
# `gpforum help --all` only.
const my @GROUPS => qw(setup run check maintain more);

const my $FRONT_DOOR => 'gpforum';

# How the documents ran an entrypoint before the front door, which the front
# door's own name replaces whole.
const my $CARTON_EXEC =>
  qr{script/gpforum-carton \s+ exec \s+ (?: perl \s+ -Ilib \s+ )?}msx;

# A bin/ entrypoint named in a text, relative to the checkout: not a path
# under another directory, such as /opt/gpforum/bin/gpforum-migrate in a unit.
const my $ENTRY_NAME => qr{gpforum-[[:lower:]]+ (?:-[[:lower:]]+)*}msx;
const my $ENTRYPOINT =>
  qr{(?<![\w/.]) (?:[.]/)? bin/ ($ENTRY_NAME) (?![\w-])}msx;

# The option an entrypoint needed spelt out and its verb does without being
# told: bin/gpforum-migrate only plans, gpforum migrate applies. A sentence
# that offered `gpforum migrate --apply` named a switch the verb's own help
# does not list.
const my %IMPLIED => ( 'gpforum-migrate' => '--apply' );

sub groups ($class) {
    return [@GROUPS];
}

# Every verb, in the help's order, as { verb, group, command, entrypoint,
# typed, needs }: the verb typed, its group, the GPForum::CLI command that
# does the work, its bin/ entrypoint (undef for a verb without one), what
# to type for it in full (`admin grant` for the entrypoint that only ever
# granted), and what it needs beyond the settings -- "application" for one
# that runs the web application.
sub verbs ($class) {
    return [ map { _verb($_) } @VERBS ];
}

sub find ( $class, $verb ) {
    return first { $_->{verb} eq $verb } @{ $class->verbs };
}

# What the operator types for a bin/ entrypoint, such as `gpforum
# partitions` for bin/gpforum-partition-maintenance, or undef for a name
# that is not one.
sub typed_for_entrypoint ( $class, $entrypoint ) {
    my $verb =
      first { ( $_->{entrypoint} // q{} ) eq $entrypoint } @{ $class->verbs };
    my $typed = $verb ? $verb->{typed} : undef;
    if ( !$verb && exists $OTHER_ENTRYPOINT{$entrypoint} ) {
        $typed = $OTHER_ENTRYPOINT{$entrypoint};
    }
    return defined $typed ? "$FRONT_DOOR $typed" : undef;
}

# A text with every bin/gpforum-NAME it names written as the front door's
# verb, for an operator who came in through the front door.
sub as_typed ( $class, $text ) {
    return $text if !defined $text;

    $text =~ s{ ($CARTON_EXEC)? $ENTRYPOINT (?: [ ] (--[[:lower:]-]+) )? }
              { _typed( $class->typed_for_entrypoint($2), $1, $2, $3 ) }gemsx;

    return $text;
}

# An entrypoint and the option after it as the front door types them, or as
# they were when the entrypoint has no verb.
sub _typed ( $typed, $carton, $entrypoint, $option ) {
    my $after = defined $option ? " $option" : q{};
    return ( $carton // q{} ) . "bin/$entrypoint$after" if !defined $typed;

    my $implied = exists $IMPLIED{$entrypoint} ? $IMPLIED{$entrypoint} : q{};
    return defined $option && $option eq $implied ? $typed : "$typed$after";
}

sub _verb ($row) {
    my ( $verb, $group, $command, $entrypoint, $typed, $needs ) = @{$row};

    return {
        command    => $command,
        entrypoint => $entrypoint,
        group      => $group,
        needs      => $needs,
        typed      => $typed // $verb,
        verb       => $verb,
    };
}

1;

__END__

=head1 NAME

GPForum::Command::Support::Verbs - What an operator types after C<gpforum>.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $verb = GPForum::Command::Support::Verbs->find('partitions');
    # { verb => 'partitions', group => 'maintain',
    #   command => 'partition_maintenance',
    #   entrypoint => 'gpforum-partition-maintenance', ... }

    say GPForum::Command::Support::Verbs->as_typed(
        'run bin/gpforum-partition-maintenance --plan');
    # run gpforum partitions --plan

=head1 DESCRIPTION

The front door's verbs, grouped as its help shows them -- set up, run,
check, maintain, and more -- each with the C<GPForum::CLI> command that does
the work and the C<bin/> entrypoint that keeps working as its alias.

=head1 SUBROUTINES/METHODS

=head2 groups

Class method. The group names in the help's order.

=head2 verbs

Class method. Every verb, in the help's order, as a hash reference with
C<verb>, C<group>, C<command>, C<entrypoint>, C<typed> and C<needs>.

=head2 find

Class method. The verb typed, or undef.

=head2 typed_for_entrypoint

Class method. What to type at the front door for a C<bin/> entrypoint's
name (C<gpforum-partition-maintenance> gives C<gpforum partitions>), or
undef.

=head2 as_typed

Class method. A text with each C<bin/gpforum-NAME> it names written as the
front door's verb, without an option the verb implies (C<bin/gpforum-migrate
--apply> gives C<gpforum migrate>).

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<List::Util>, L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A verb whose command is not installed (C<doctor> before it lands) is in the
table all the same; the front door shows only the ones it can load.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
