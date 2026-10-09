# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;
use utf8;

use File::Temp  qw(tempdir);
use Test::Fatal qw(exception);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Attachment::FilesystemStorage;
use GPForum::Service::Operations::DeadLetterCheck;
use GPForum::Service::Operations::MailLifecycleCheck;
use GPForum::Service::Operations::RateLimiter::DegradationPolicy;
use GPForum::Service::Operations::StagingDrill;
use GPForum::Service::Operations::StressLoad;
use GPForum::Service::Password;
use GPForum::X::Argument;
use GPForum::X::Config;

our $VERSION = '0.001';

# These services raised their own message strings with croak; they raise the
# GPForum::X class that says what went wrong (ADR 0118), with the same
# message. A broken call is an X::Argument, a configuration that cannot work
# is an X::Config.

my $storage = GPForum::Service::Attachment::FilesystemStorage->new(
    root => tempdir( CLEANUP => 1 ) );
_refused(
    'GPForum::X::Argument',
    sub { $storage->write_object( 'a/b', undef ) },
    'attachment content is required',
    'writing no content'
);
for my $case (
    [ undef,    'attachment object key is required',      'no key' ],
    [ '/etc/x', 'attachment object key must be relative', 'an absolute key' ],
    [ 'a/../b', 'attachment object key is unsafe',        'a key with ..' ],
    [ 'a b',    'attachment object key is unsafe', 'a key with a space' ],
    [ 'café',   'attachment object key is unsafe', 'a key that is not ASCII' ],
  )
{
    my ( $key, $message, $name ) = @{$case};
    _refused( 'GPForum::X::Argument', sub { $storage->path_for($key) },
        $message, $name );
}

my $password = GPForum::Service::Password->new;
_refused(
    'GPForum::X::Argument',
    sub { $password->hash_password(q{}) },
    'password is required',
    'hashing an empty password'
);
_refused(
    'GPForum::X::Argument',
    sub { $password->hash_password('short') },
qr/\A password [ ] must [ ] be [ ] at [ ] least [ ] \d+ [ ] characters \z/msx,
    'hashing a short password'
);

_refused(
    'GPForum::X::Argument',
    sub {
        GPForum::Service::Operations::DeadLetterCheck->new->run(
            { mode => 'live' } );
    },
    'Unsupported dead-letter-check mode: live',
    'an unknown dead-letter-check mode'
);
_refused(
    'GPForum::X::Argument',
    sub {
        GPForum::Service::Operations::MailLifecycleCheck->new->run(
            { mode => 'live' } );
    },
    'Unsupported mail-lifecycle-check mode: live',
    'an unknown mail-lifecycle-check mode'
);

my $stress = GPForum::Service::Operations::StressLoad->new;
_refused(
    'GPForum::X::Argument',
    sub { $stress->plan( { profile => 'huge' } ) },
    'Unsupported stress profile: huge',
    'an unknown stress profile'
);
_refused(
    'GPForum::X::Argument',
    sub { $stress->run( { profile => 'smoke' } ) },
    'GPForum stress-load requires --base-url (running Hypnotoad/app)',
    'a stress run with no target'
);

_refused(
    'GPForum::X::Config',
    sub {
        GPForum::Service::Operations::RateLimiter::DegradationPolicy->new(
            mode => 'sometimes' );
    },
    'unknown rate limiter degradation mode: sometimes',
    'an unknown degradation mode'
);

my $drill = GPForum::Service::Operations::StagingDrill->new;
_refused(
    'GPForum::X::Config',
    sub { $drill->parse_dsn('dbi:Pg:host=127.0.0.1') },
    'DSN is missing dbname=',
    'a DSN with no database'
);
_refused(
    'GPForum::X::Config',
    sub { $drill->rewrite_dsn( 'dbi:Pg:host=127.0.0.1', 'drill' ) },
    'GPFORUM_DATABASE_DSN must name a database with dbname=',
    'rewriting a DSN with no database'
);

done_testing();

sub _refused ( $class, $code, $message, $name ) {
    my $error = exception { $code->() };
    ok( $class->caught($error), "$name is refused as $class" );
    if ( ref $message ) {
        like( "$error", $message, "$name keeps its message" );
    }
    else {
        is( "$error", $message, "$name keeps its message, and only it" );
    }

    return;
}

1;
