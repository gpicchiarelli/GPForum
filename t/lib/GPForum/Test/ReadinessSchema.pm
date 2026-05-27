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
has search_count => 0;

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
    my ($self) = @_;

    $self->search_count( $self->search_count + 1 );

    return $self;
}

sub single {
    return;
}

1;
