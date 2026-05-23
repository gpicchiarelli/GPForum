package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';

use GPForum::Service::Identity::Registration;

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 11;

plan tests => $EXPECTED_TESTS;

my $registration = GPForum::Service::Identity::Registration->new;

my $invalid = $registration->prepare(
    {
        username     => 'x',
        display_name => q{},
        email        => 'not-mail',
        password     => 'short',
    }
);

ok( !$invalid->{ok}, 'invalid registration is rejected' );
is(
    $invalid->{errors}{username},
    'username length is invalid',
    'username length is validated'
);
is(
    $invalid->{errors}{display_name},
    'display name is required',
    'display name is validated'
);
is(
    $invalid->{errors}{email},
    'email format is invalid',
    'email format is validated'
);
like(
    $invalid->{errors}{password},
    qr/\A password [ ] must/msx,
    'password length is validated'
);

my $valid = $registration->prepare(
    {
        username     => 'Giacomo_Forum',
        display_name => ' Giacomo Picchiarelli ',
        email        => 'GIACOMO@example.test',
        password     => 'correct horse battery staple',
    }
);

ok( $valid->{ok}, 'valid registration is prepared' );
is( $valid->{registration}{user}{username},
    'giacomo_forum', 'username is normalized' );
is(
    $valid->{registration}{user}{display_name},
    'Giacomo Picchiarelli',
    'display name is trimmed'
);
is( $valid->{registration}{user}{email_normalized},
    'giacomo@example.test', 'email is normalized' );
is( $valid->{registration}{credential}{type},
    'password', 'password credential is prepared' );
like(
    $valid->{registration}{credential}{secret_hash},
    qr/\A \x{24} argon2id \x{24} /msx,
    'registration stores an Argon2id secret hash'
);

1;
