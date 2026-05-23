package GPForum::Test::ReadinessSchema;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Service::Operations::QueryBudget;
use GPForum::Test::QueryBudgetResultSet;
use GPForum::Test::QueryBudgetSchema;

our $VERSION = '0.001';

has query_budget_resultset => sub {
    my $resultset = GPForum::Test::QueryBudgetResultSet->new;
    GPForum::Service::Operations::QueryBudget->new->sync_schema(
        GPForum::Test::QueryBudgetSchema->new(
            budget_resultset => $resultset,
        )
    );

    return $resultset;
};

sub storage {
    my ($self) = @_;

    return $self;
}

sub dbh {
    my ($self) = @_;

    return $self;
}

sub selectrow_array {
    return 1;
}

sub resultset {
    my ( $self, $name ) = @_;

    return $self->query_budget_resultset
      if defined $name && $name eq 'EndpointQueryBudget';

    return $self;
}

sub search {
    return;
}

1;
