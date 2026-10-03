# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use English qw(-no_match_vars);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Base;
use GPForum::Test::RequiresNothing;
use GPForum::Test::RequiresStore;
use GPForum::Test::RequiresSubStore;
use GPForum::X::Argument;

our $VERSION = '0.001';

my $store_class = 'GPForum::Test::RequiresStore';
my $sub_class   = 'GPForum::Test::RequiresSubStore';

# Arguments as a list of pairs or as a hash reference, as Mojo::Base takes.
is( $store_class->new( schema => 'db' )->schema,
    'db', 'a required attribute passed as a pair is set' );
is( $store_class->new( { schema => 'db' } )->schema,
    'db', 'and passed in a hash reference' );
ok( $store_class->new( schema => 0 ),   'a false but defined value is given' );
ok( $store_class->new( schema => q{} ), 'and so is the empty string' );

# A missing or undef required attribute is refused when the object is built.
my $line;
my $missing = _error_of(
    sub {
        $line = __LINE__ + 1;
        $store_class->new( logger => 'log' );
    }
);
ok( GPForum::X::Argument->caught($missing),
    'a missing one throws X::Argument' );
is( "$missing", "$store_class requires schema", 'naming the class and it' );
is(
    $missing->location,
    "t/323-base-requires.t line $line",
    'from the line that called new'
);
ok( GPForum::X::Argument->caught( _error_of( sub { $store_class->new } ) ),
    'no arguments at all are refused' );
is(
    q{} . _error_of( sub { $store_class->new( schema => undef ) } ),
    "$store_class requires schema",
    'an undef value counts as missing'
);

# A subclass inherits its parents' required attributes and adds its own.
is(
    q{} . _error_of( sub { $sub_class->new( schema => 'db' ) } ),
    "$sub_class requires recorder",
    'a subclass checks its own required attributes'
);
is(
    q{} . _error_of( sub { $sub_class->new( recorder => 'r' ) } ),
    "$sub_class requires schema",
    'and the ones it inherits'
);
is(
    q{} . _error_of( sub { $sub_class->new } ),
    "$sub_class requires schema, recorder",
    'naming every missing one, inherited first'
);
ok( $sub_class->new( schema => 'db', recorder => 'r' ),
    'and builds when all are given' );

# The list is introspectable, from the class or an object.
is_deeply( [ $store_class->required_attributes ],
    ['schema'], 'required_attributes lists a class\'s own' );
is_deeply( [ $sub_class->required_attributes ],
    [qw(schema recorder)], 'inherited first, a redeclared name once' );
is_deeply(
    [ $sub_class->new( schema => 1, recorder => 1 )->required_attributes ],
    [qw(schema recorder)], 'and answers on an object too' );
is_deeply( [ GPForum::Test::RequiresNothing->required_attributes ],
    [], 'a class that requires nothing lists nothing' );
ok( GPForum::Test::RequiresNothing->new, 'and builds without arguments' );
ok( GPForum::Base->new,                  'as does GPForum::Base itself' );

# Other attributes behave as before: a lazy default is built on first read.
my $store = $store_class->new( schema => 'db' );
ok( !exists $store->{clock}, 'new does not build a lazy default' );
is( $store->clock, 'clock', 'which is built on first read' );
ok( !defined $store->logger, 'an optional attribute stays undef' );
is( $store->schema('other')->schema,
    'other', 'a required attribute is an ordinary accessor' );

# requires itself refuses what it cannot declare.
ok(
    GPForum::X::Argument->caught(
        _error_of( sub { $store_class->requires(q{}) } )
    ),
    'an empty attribute name is refused'
);
is(
    q{} . _error_of( sub { $store->requires('cache') } ),
    "requires is a class method, called on $store_class",
    'and so is a call on an object'
);
is(
    GPForum::Test::RequiresNothing->requires,
    'GPForum::Test::RequiresNothing',
    'requires returns the class'
);

done_testing();

# What the code died with; undef when it did not.
sub _error_of ($code) {
    if ( eval { $code->(); 1 } ) {
        return undef;
    }

    return $EVAL_ERROR;
}

1;
