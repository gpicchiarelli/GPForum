package GPForum::Test::AuditChainStorage;

use Mojo::Base 'GPForum::Test::BareStorage';
use v5.40;

our $VERSION = '0.001';

has schema => undef;

# The storage is its own handle. Like a DBI handle it reports AutoCommit,
# false only inside a transaction: UniqueConflict takes a savepoint only when
# it is false, and DBIx::Class refuses a savepoint outside a transaction.
sub dbh {
    my ($self) = @_;

    $self->{AutoCommit} = $self->transaction_depth ? 0 : 1;

    return $self;
}

sub selectrow_array {
    my ( $self, $sql, undef, @bind ) = @_;

    $self->schema->record_step( 'lock', $sql );

    return $bind[0];
}

# Not DBIx::Class's: its storage keeps the depth as transaction_depth only,
# so on PostgreSQL EventRecorder::_needs_transaction, which asks for this
# name, never opens the transaction its advisory lock needs. Kept only while
# that and t/159 and t/316 still use it; drop it when they ask for
# transaction_depth.
sub txn_depth {
    my ( $self, @depth ) = @_;

    return $self->transaction_depth(@depth);
}

1;
