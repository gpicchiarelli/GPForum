package GPForum::Service::Operations::QueryBudget;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

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
);

has budgets => sub { return _default_budgets(); };
has schema  => undef;

sub catalog {
    my ($self) = @_;

    my %catalog = %{ $self->budgets };

    return \%catalog;
}

sub budget_for {
    my ( $self, $endpoint_name ) = @_;

    return if !defined $endpoint_name;
    return if !exists $self->budgets->{$endpoint_name};

    return { %{ $self->budgets->{$endpoint_name} } };
}

sub observe {
    my ( $self, $endpoint_name, $observation ) = @_;

    my $budget = $self->budget_for($endpoint_name);
    return _unknown_endpoint($endpoint_name) if !$budget;

    my $queries      = _observed_value( $observation, 'queries' );
    my $transactions = _observed_value( $observation, 'transactions' );
    my @violations;

    if ( $queries > $budget->{max_queries} ) {
        push @violations, 'queries';
    }
    if ( $transactions > $budget->{max_transactions} ) {
        push @violations, 'transactions';
    }

    return {
        endpoint_name => $endpoint_name,
        status        => @violations ? 'fail' : 'ok',
        budget        => $budget,
        observed      => {
            queries      => $queries,
            transactions => $transactions,
        },
        violations => \@violations,
    };
}

sub snapshot {
    my ($self) = @_;

    return { endpoints =>
          { map { $_ => $self->budget_for($_) } sort keys %{ $self->budgets } },
    };
}

sub sync_schema {
    my ( $self, $schema ) = @_;

    my $resultset = $self->_resultset($schema);
    my @endpoints = sort keys %{ $self->budgets };

    for my $endpoint_name (@endpoints) {
        $resultset->update_or_create(
            _storage_row( $self->budget_for($endpoint_name) ) );
    }

    return {
        synced    => scalar @endpoints,
        endpoints => \@endpoints,
    };
}

sub drift_report {
    my ( $self, $schema ) = @_;

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
            endpoint_name     => $endpoint_name,
            max_queries       => $DEFAULT_BUDGETS{$endpoint_name}{max_queries},
            max_transactions  => $DEFAULT_TRANSACTION_BUDGET,
            notes             => $DEFAULT_BUDGETS{$endpoint_name}{notes},
            enforcement_level => 'release-gate',
        };
    }

    return \%budgets;
}

sub _observed_value {
    my ( $observation, $name ) = @_;

    return 0 if !$observation;
    return 0 if !exists $observation->{$name};

    return int $observation->{$name};
}

sub _unknown_endpoint {
    my ($endpoint_name) = @_;

    return {
        endpoint_name => $endpoint_name,
        status        => 'unknown',
        budget        => undef,
        observed      => {},
        violations    => ['endpoint'],
    };
}

sub _resultset {
    my ( $self, $schema ) = @_;

    if ( !$schema ) {
        $schema = $self->schema;
    }

    return $schema->resultset('EndpointQueryBudget');
}

sub _storage_row {
    my ($budget) = @_;

    return {
        endpoint_name    => $budget->{endpoint_name},
        max_queries      => $budget->{max_queries},
        max_transactions => $budget->{max_transactions},
        notes            => $budget->{notes},
    };
}

sub _stored_budget_rows {
    my ( $self, $schema ) = @_;

    my $search = $self->_resultset($schema)->search(
        {},
        {
            rows     => $BUDGET_SEARCH_ROWS,
            order_by => { -asc => 'endpoint_name' },
        },
    );

    return map { _column( $_, 'endpoint_name' ) => $_ } _rows($search);
}

sub _missing_endpoints {
    my ( $catalog, $stored ) = @_;

    return grep { !exists $stored->{$_} } sort keys %{$catalog};
}

sub _extra_endpoints {
    my ( $catalog, $stored ) = @_;

    return grep { !exists $catalog->{$_} } sort keys %{$stored};
}

sub _mismatched_endpoints {
    my ( $catalog, $stored ) = @_;

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

sub _budget_mismatch {
    my ( $budget, $row ) = @_;

    return 1 if _column( $row, 'max_queries' ) != $budget->{max_queries};
    return 1
      if _column( $row, 'max_transactions' ) != $budget->{max_transactions};

    return 0;
}

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _column {
    my ( $row, $column ) = @_;

    return $row->get_column($column) if $row->can('get_column');

    return $row->{$column};
}

1;
