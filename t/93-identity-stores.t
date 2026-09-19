package main;

use strict;
use warnings;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Identity::Support;
use Test::More;

our $VERSION = '0.001';

my $support = GPForum::Service::Identity::Support->new;
is( $support->trim('  giacomo  '),
    'giacomo', 'support trims surrounding whitespace' );
is( $support->normalize_identifier('Giacomo@Example.TEST'),
    'giacomo@example.test', 'support normalizes identifiers' );
is( $support->column( { id => 'user-1' }, 'id' ),
    'user-1', 'support reads hash columns' );
ok( !$support->has_text(q{}),             'empty strings are not text' );
ok( !defined $support->hash_value(undef), 'empty hashes are not stored' );
my $hash = $support->hash_value('198.51.100.10');
ok( $hash && $hash ne '198.51.100.10',
    'support hashes identifiers before persistence' );

done_testing();

1;
