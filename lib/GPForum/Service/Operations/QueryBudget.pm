# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::QueryBudget;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::UniqueConflict;

our $VERSION = '0.001';

const my $DEFAULT_TRANSACTION_BUDGET => 1;
const my $BUDGET_SEARCH_ROWS         => 1_000;
const my %DEFAULT_BUDGETS => (
    home => {
        max_queries => 5,
        notes       => 'forum index and read-mostly sidebar',
    },
    categories => {
        max_queries => 3,
        notes       => 'category list projection or bounded canonical read',
    },
    category_threads => {
        max_queries => 5,
        notes       => 'category head plus keyset thread list',
    },
    admin_dashboard => {
        max_queries => 6,
        notes       => 'authorized admin role summary plus recent audit',
    },
    admin_users => {
        max_queries => 5,
        notes       => 'authorized bounded admin user directory',
    },
    admin_roles => {
        max_queries => 6,
        notes       => 'authorized role and permission catalog review',
    },
    admin_role_update => {
        max_queries => 6,
        notes       => 'role, permission, or scoped binding write workflow',
    },
    admin_user_roles => {
        max_queries => 5,
        notes       => 'authorized active role binding review for one user',
    },
    admin_audit => {
        max_queries => 5,
        notes       => 'authorized bounded admin audit review',
    },
    admin_jobs => {
        max_queries => 6,
        notes       => 'authorized bounded async outbox and dead-letter review',
    },
    admin_status => {
        max_queries => 8,
        notes       => 'authorized read-only health and runtime status',
    },
    thread_view => {
        max_queries => 8,
        notes       => 'thread head, posts, authors, counters, permissions',
    },
    thread_create => {
        max_queries => 6,
        notes       => 'single canonical transaction plus outbox handoff',
    },
    reply_create => {
        max_queries => 6,
        notes       => 'single canonical transaction plus position allocation',
    },
    report_create => {
        max_queries => 5,
        notes       => 'visible target check plus report event/audit/outbox',
    },
    moderation_reports => {
        max_queries => 5,
        notes       => 'authorized moderation report queue read',
    },
    moderation_actions => {
        max_queries => 5,
        notes       => 'authorized moderation action history read',
    },
    moderation_suspensions => {
        max_queries => 5,
        notes       => 'authorized user suspension review read',
    },
    report_update => {
        max_queries => 5,
        notes       => 'authorized report assignment or resolution workflow',
    },
    moderation_action => {
        max_queries => 6,
        notes       => 'content moderation action plus event/audit/outbox',
    },
    user_suspension => {
        max_queries => 6,
        notes       => 'user suspension or revocation plus event/audit/outbox',
    },
    search => {
        max_queries => 2,
        notes       => 'permission-aware search projection lookup',
    },
    search_autocomplete => {
        max_queries => 2,
        notes => 'bounded permission-aware autocomplete projection lookup',
    },
    notifications => {
        max_queries => 4,
        notes       => 'bounded inbox read plus unread counter',
    },
    metrics => {
        max_queries => 5,
        notes => 'rate limit buckets, budget drift, outbox and dead letters',
    },
);

has budgets => sub { return _default_budgets(); };
has schema  => undef;

sub catalog ($self) {
    my %catalog = %{ $self->budgets };

    return \%catalog;
}

sub budget_for ( $self, $endpoint_name ) {
    my $undefined;
    return $undefined if !defined $endpoint_name;
    return $undefined if !exists $self->budgets->{$endpoint_name};

    return { %{ $self->budgets->{$endpoint_name} } };
}

sub observe ( $self, $endpoint_name, $observation ) {
    my $budget = $self->budget_for($endpoint_name);
    return _unknown_endpoint($endpoint_name) if !$budget;

    my $queries      = _observed_value( $observation, 'queries' );
    my $transactions = _observed_value( $observation, 'transactions' );
    my $duplicates   = _observed_value( $observation, 'duplicate_queries' );
    my @violations;

    if ( $queries > $budget->{max_queries} ) {
        push @violations, 'queries';
    }
    if ( $transactions > $budget->{max_transactions} ) {
        push @violations, 'transactions';
    }
    if ( $duplicates > $budget->{max_duplicate_queries} ) {
        push @violations, 'duplicate_queries';
    }

    return {
        endpoint_name => $endpoint_name,
        status        => @violations ? 'fail' : 'ok',
        budget        => $budget,
        observed      => {
            duplicate_queries => $duplicates,
            queries           => $queries,
            transactions      => $transactions,
        },
        violations => \@violations,
    };
}

sub enforce ( $self, $endpoint_name, $observation ) {
    my $result = $self->observe( $endpoint_name, $observation );
    die _failure_message($result)
      if ( $result->{status} || q{} ) eq 'fail';

    return $result;
}

sub snapshot ($self) {
    return { endpoints =>
          { map { $_ => $self->budget_for($_) } sort keys %{ $self->budgets } },
    };
}

sub sync_schema ( $self, $schema = undef ) {
    my $resultset = $self->_resultset($schema);
    my %stored    = $self->_stored_budget_rows($schema);
    my @endpoints = sort keys %{ $self->budgets };
    my $written   = 0;

    for my $endpoint_name (@endpoints) {
        $written += $self->_sync_endpoint(
            {
                endpoint_name => $endpoint_name,
                stored        => $stored{$endpoint_name},
                resultset     => $resultset,
            }
        );
    }

    my @removed = _remove_dropped( $resultset, $self->catalog, \%stored );

    return {
        endpoints => \@endpoints,
        removed   => \@removed,
        skipped   => scalar(@endpoints) - $written,
        synced    => scalar @endpoints,
        written   => $written,
    };
}

# A row for an endpoint the catalog no longer has is deleted: the table is a
# copy of the catalog, and drift_report fails on it as 'extra'. Sync used to
# leave it, so the check failed after every sync until someone deleted it by
# hand.
sub _remove_dropped ( $resultset, $catalog, $stored ) {
    my @dropped = _extra_endpoints( $catalog, $stored );
    return if !@dropped;

    $resultset->search_rs( { endpoint_name => { -in => \@dropped } } )->delete;

    return @dropped;
}

sub _sync_endpoint ( $self, $job ) {
    $job->{row} = _storage_row( $self->budget_for( $job->{endpoint_name} ) );
    if ( _unchanged_budget( $job->{stored}, $job->{row} ) ) {
        return 0;
    }

    return $self->_persist_budget($job);
}

sub _persist_budget ( $self, $job ) {
    if ( $job->{stored} ) {
        $job->{resultset}->update_or_create( $job->{row} );
        return 1;
    }

    return $self->_insert_or_reuse_budget($job);
}

sub _insert_or_reuse_budget ( $self, $job ) {
    my ( $created, $error ) =
      GPForum::Infrastructure::UniqueConflict->attempt( $self->schema,
        sub { return $self->_create_budget($job); },
      );
    if ($created) {
        return 1;
    }

    return $self->_budget_after_conflict( $job, $error );
}

sub _create_budget ( $self, $job ) {
    return $job->{resultset}->create( $job->{row} );
}

sub _budget_after_conflict ( $self, $job, $error ) {
    if ( !GPForum::Infrastructure::UniqueConflict->is_conflict($error) ) {
        GPForum::Infrastructure::UniqueConflict->rethrow($error);
    }

    $job->{error} = $error;
    return $self->_reuse_budget($job);
}

sub _reuse_budget ( $self, $job ) {
    my $stored = $job->{resultset}->find( $job->{endpoint_name} );
    if ( _unchanged_budget( $stored, $job->{row} ) ) {
        return 0;
    }
    if ( !$stored ) {
        GPForum::Infrastructure::UniqueConflict->rethrow( $job->{error} );
    }

    $job->{resultset}->update_or_create( $job->{row} );
    return 1;
}

sub _unchanged_budget ( $held, $incoming ) {
    if ( !$held ) {
        return 0;
    }
    if ( _budget_mismatch( $incoming, $held ) ) {
        return 0;
    }

    return _same_text( _column( $held, 'notes' ), $incoming->{notes} );
}

sub _same_text ( $held, $incoming ) {
    return _same_notes( _text($held), _text($incoming) );
}

sub _text ($value) {
    if ( defined $value ) {
        return $value;
    }

    return q{};
}

sub _same_notes ( $held, $incoming ) {
    if ( $held eq $incoming ) {
        return 1;
    }

    return 0;
}

sub drift_report ( $self, $schema = undef ) {
    my %stored     = $self->_stored_budget_rows($schema);
    my $catalog    = $self->catalog;
    my @missing    = _missing_endpoints( $catalog, \%stored );
    my @extra      = _extra_endpoints( $catalog, \%stored );
    my @mismatched = _mismatched_endpoints( $catalog, \%stored );

    return {
        status     => @missing || @extra || @mismatched ? 'fail' : 'ok',
        missing    => \@missing,
        extra      => \@extra,
        mismatched => \@mismatched,
    };
}

sub _default_budgets {
    my %budgets;

    for my $endpoint_name ( keys %DEFAULT_BUDGETS ) {
        $budgets{$endpoint_name} = {
            endpoint_name    => $endpoint_name,
            max_queries      => $DEFAULT_BUDGETS{$endpoint_name}{max_queries},
            max_transactions => $DEFAULT_TRANSACTION_BUDGET,
            max_duplicate_queries => 0,
            notes                 => $DEFAULT_BUDGETS{$endpoint_name}{notes},
            enforcement_level     => 'release-gate',
        };
    }

    return \%budgets;
}

sub _observed_value ( $observation, $name ) {
    return 0 if !$observation;
    return 0 if !exists $observation->{$name};

    return int $observation->{$name};
}

sub _unknown_endpoint ($endpoint_name) {
    return {
        endpoint_name => $endpoint_name,
        status        => 'unknown',
        budget        => undef,
        observed      => {},
        violations    => ['endpoint'],
    };
}

sub _failure_message ($result) {
    return join q{:},
      'query budget exceeded',
      $result->{endpoint_name},
      join q{,}, @{ $result->{violations} || [] };
}

sub _resultset ( $self, $schema ) {
    if ( !$schema ) {
        $schema = $self->schema;
    }

    return $schema->resultset('EndpointQueryBudget');
}

sub _storage_row ($budget) {
    return {
        endpoint_name    => $budget->{endpoint_name},
        max_queries      => $budget->{max_queries},
        max_transactions => $budget->{max_transactions},
        notes            => $budget->{notes},
    };
}

sub _stored_budget_rows ( $self, $schema ) {
    my $search = $self->_resultset($schema)->search_rs(
        {},
        {
            rows     => $BUDGET_SEARCH_ROWS,
            order_by => { -asc => 'endpoint_name' },
        },
    );

    return map { _column( $_, 'endpoint_name' ) => $_ } _rows($search);
}

sub _missing_endpoints ( $catalog, $stored ) {
    return grep { !exists $stored->{$_} } sort keys %{$catalog};
}

sub _extra_endpoints ( $catalog, $stored ) {
    return grep { !exists $catalog->{$_} } sort keys %{$stored};
}

sub _mismatched_endpoints ( $catalog, $stored ) {
    my @mismatched;
    for my $endpoint_name ( sort keys %{$catalog} ) {
        next if !exists $stored->{$endpoint_name};
        if (
            _budget_mismatch(
                $catalog->{$endpoint_name},
                $stored->{$endpoint_name}
            )
          )
        {
            push @mismatched, $endpoint_name;
        }
    }

    return @mismatched;
}

sub _budget_mismatch ( $budget, $row ) {
    return 1 if _column( $row, 'max_queries' ) != $budget->{max_queries};
    return 1
      if _column( $row, 'max_transactions' ) != $budget->{max_transactions};

    return 0;
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _column ( $row, $column ) {
    return $row->get_column($column) if $row->can('get_column');

    return $row->{$column};
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::QueryBudget - Per-endpoint query and transaction budgets, checked per request and kept in the database.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $budgets =
      GPForum::Service::Operations::QueryBudget->new( schema => $schema );

    my $result = $budgets->observe( 'thread_view',
        { duplicate_queries => 0, queries => 7, transactions => 1 } );
    # $result->{status} is 'ok', 'fail' or 'unknown'

    $budgets->enforce( 'thread_view', $observation );    # dies on 'fail'

    $budgets->sync_schema;
    my $drift = $budgets->drift_report;

=head1 DESCRIPTION

The catalog of how much database work each named endpoint may do: a
C<max_queries> per endpoint, from 2 for search to 8 for the thread view and
the admin status page, at most one transaction and no duplicate query, all
at the C<release-gate> enforcement level. The request hook in
L<GPForum::Bootstrap::Operations> observes every request that carries an
endpoint name against it, and the benchmark reads its budgets.

The C<endpoint_query_budgets> table holds a copy of the catalog:
C<sync_schema> makes it match (C<bin/gpforum-query-budget --sync>) and
C<drift_report> compares it, for the platform check, readiness, the metrics
snapshot and the admin console.

=head1 SUBROUTINES/METHODS

=head2 catalog

Returns a shallow copy of the budgets hash, keyed by endpoint name.

=head2 budget_for

Takes an endpoint name. Returns a copy of its budget (C<endpoint_name>,
C<max_queries>, C<max_transactions>, C<max_duplicate_queries>, C<notes>,
C<enforcement_level>), or undef for an unknown or undef name.

=head2 observe

Takes an endpoint name and a hash reference of the observed C<queries>,
C<transactions> and C<duplicate_queries>; a missing one counts as 0 and the
others are truncated to integers. Returns
C<< { endpoint_name, status, budget, observed, violations } >>: status
C<fail>, with each exceeded measure named in C<violations>, or C<ok>. For an
unknown endpoint the status is C<unknown>, the budget undef and the
violations C<['endpoint']>.

=head2 enforce

Takes the same arguments as C<observe> and returns its result, but dies
when the status is C<fail>. An unknown endpoint does not die.

=head2 snapshot

Returns C<< { endpoints => { NAME => \%budget, ... } } >> with a copy of
every budget.

=head2 sync_schema

Takes an optional schema; the object's is used without one. Writes the
catalog to C<endpoint_query_budgets>: rows whose C<max_queries>,
C<max_transactions> and C<notes> already match are left alone, the others
updated or inserted, and rows for endpoints the catalog no longer has are
deleted. An insert that loses a race to another writer re-reads the row and
updates it if it still differs. Returns
C<< { endpoints, removed, synced, written, skipped } >>: the endpoint names,
the names whose rows were deleted, the number of endpoints, the rows written
and the rows left as they were.

=head2 drift_report

Takes an optional schema. Compares the stored rows (up to 1,000) with the
catalog. Returns C<< { status, missing, extra, mismatched } >>: the
endpoints in the catalog but not stored, stored but not in the catalog, and
stored with a different C<max_queries> or C<max_transactions>; the status
is C<fail> when any list is not empty and C<ok> otherwise.

=head1 DIAGNOSTICS

C<enforce> dies with C<query budget exceeded:ENDPOINT:VIOLATIONS>, the
violations joined by commas. C<sync_schema> rethrows with C<croak> an insert
error that is not a unique violation, and a unique violation whose row
cannot then be found. Other database errors propagate.

=head1 CONFIGURATION AND ENVIRONMENT

The C<budgets> attribute replaces the built-in catalog.

=head1 DEPENDENCIES

L<GPForum::Infrastructure::UniqueConflict>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
