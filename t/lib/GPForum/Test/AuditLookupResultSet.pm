package GPForum::Test::AuditLookupResultSet;

use Mojo::Base 'GPForum::Test::ResultSet';
use v5.40;

our $VERSION = '0.001';

sub search_rs {
    my ( $self, $query, @rest ) = @_;

    if ( $self->_audit_id_lookup($query) ) {
        $self->schema->record_step('lookup');
    }

    return $self->SUPER::search_rs( $query, @rest );
}

sub _audit_id_lookup {
    my ( $self, $query ) = @_;

    if ( $self->name ne 'AuditLog' || ref $query ne 'HASH' ) {
        return 0;
    }

    return exists $query->{audit_id} ? 1 : 0;
}

1;
