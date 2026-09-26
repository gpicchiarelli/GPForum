package GPForum::Test::AuditChainStorage;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has schema    => undef;
has txn_depth => 0;

sub dbh {
    my ($self) = @_;

    return $self;
}

sub selectrow_array {
    my ( $self, $sql, undef, @bind ) = @_;

    $self->schema->record_step( 'lock', $sql );

    return $bind[0];
}

1;
