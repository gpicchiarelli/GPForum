package GPForum::Test::QueryPlanEvidenceDbh;

use strict;
use warnings;

use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base;

our $VERSION = '0.001';

has plan => sub {
    return {
        Plan => {
            'Node Type'     => 'Index Scan',
            'Relation Name' => 'threads',
            'Plan Rows'     => 10,
            'Actual Rows'   => 10,
            'Total Cost'    => 1,
        },
    };
};

sub selectrow_array {
    my ($self) = @_;

    return encode_json( [ $self->plan ] );
}

1;
