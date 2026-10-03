package GPForum::Test::AuditLookupSchema;

use strict;
use warnings;

use Mojo::Base 'GPForum::Test::AuditChainSchema';

use GPForum::Test::AuditLookupResultSet;

our $VERSION = '0.001';

# An audit chain schema whose journal also records each lookup by audit id,
# so a test sees where it falls against the chain lock.
sub resultset {
    my ( $self, $name ) = @_;

    return GPForum::Test::AuditLookupResultSet->new(
        schema => $self,
        name   => $name,
    );
}

1;
