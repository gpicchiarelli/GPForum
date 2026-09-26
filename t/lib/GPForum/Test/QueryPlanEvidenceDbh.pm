# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::QueryPlanEvidenceDbh;

use strict;
use warnings;

use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base;

our $VERSION = '0.001';

has plan => sub {
    return {
        Plan => {
            'Node Type'     => 'Index Scan',
            'Relation Name' => 'threads',
            'Plan Rows'     => 10,
            'Actual Rows'   => 10,
            'Total Cost'    => 1,
        },
    };
};

# The plan with sequential scans disabled; the same plan unless a test
# gives the index the planner falls back to.
has forced_plan => undef;

# What the catalog says of a table's size: large unless a test says not.
has relation_rows => 1_000_000;
has statements    => sub { return []; };
has transactions  => sub { return []; };

# Records what was EXPLAINed, so a test can check it is the application's
# SQL, and answers with the configured plan.
sub selectrow_array {
    my ( $self, $sql, undef, @bind ) = @_;

    push @{ $self->statements }, { sql => $sql, bind => \@bind };
    return $self->relation_rows if $sql =~ /\b pg_class \b/msx;

    my $plan =
        $self->{seqscan_off} && $self->forced_plan
      ? $self->forced_plan
      : $self->plan;
    return encode_json( [$plan] );
}

## no critic (Subroutines::ProhibitBuiltinHomonyms)
# The name is DBI's: the command under test calls $dbh->do, so the double must
# answer to it.
sub do {
    my ( $self, $sql ) = @_;

    push @{ $self->statements }, { sql => $sql, bind => [] };
    if ( $sql =~ /enable_seqscan [ ] = [ ] off/msx ) {
        $self->{seqscan_off} = 1;
    }

    return 1;
}
## use critic

sub begin_work {
    my ($self) = @_;

    push @{ $self->transactions }, 'begin';

    return 1;
}

sub rollback {
    my ($self) = @_;

    push @{ $self->transactions }, 'rollback';
    $self->{seqscan_off} = 0;

    return 1;
}

1;
