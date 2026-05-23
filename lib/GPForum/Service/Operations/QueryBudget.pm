package GPForum::Service::Operations::QueryBudget;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $DEFAULT_TRANSACTION_BUDGET => 1;
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
    search => {
        max_queries => 2,
        notes       => 'permission-aware search projection lookup',
    },
);

has budgets => sub { return _default_budgets(); };

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

1;
