package GPForum::Test::AuditChainSchema;

use Mojo::Base 'GPForum::Test::Schema';
use v5.40;

use GPForum::Test::AuditChainStorage;

our $VERSION = '0.001';

has journal => sub { return []; };
has storage => sub {
    my ($self) = @_;

    return GPForum::Test::AuditChainStorage->new( schema => $self );
};

sub txn_do {
    my ( $self, $code ) = @_;

    $self->transactions( $self->transactions + 1 );
    $self->storage->transaction_depth( $self->storage->transaction_depth + 1 );
    $self->record_step('begin');
    my $result = $code->();
    $self->record_step('commit');
    $self->storage->transaction_depth( $self->storage->transaction_depth - 1 );

    return $result;
}

sub record_step {
    my ( $self, $step, $sql ) = @_;

    push @{ $self->journal },
      {
        audits => scalar @{ $self->created_for('AuditLog') },
        depth  => $self->storage->transaction_depth,
        sql    => defined $sql ? $sql : q{},
        step   => $step,
      };

    return;
}

1;
