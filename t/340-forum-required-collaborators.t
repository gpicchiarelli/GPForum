# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use lib 'lib';
use lib 't/lib';

use GPForum::X::Argument;
use Test::More;

our $VERSION = '0.001';

# The collaborators each forum service cannot work without (ADR 0118), as
# t/336 pins them for the other services. A service built without one is
# refused where it is built, naming every one it lacks. PostReader was the
# last forum service whose schema was a plain `has schema => undef`: built
# without one, it failed only when a page first listed posts.
my %REQUIRED = (
    'GPForum::Service::Forum::CategoryReader'  => [qw(schema)],
    'GPForum::Service::Forum::PostingWorkflow' => [
        qw(category_reader mention_store post_composer post_reader post_store
          thread_composer thread_detail_reader thread_store)
    ],
    'GPForum::Service::Forum::PostPosition'       => [qw(schema)],
    'GPForum::Service::Forum::PostReader'         => [qw(schema)],
    'GPForum::Service::Forum::PostStore'          => [qw(schema)],
    'GPForum::Service::Forum::Readability'        => [qw(schema)],
    'GPForum::Service::Forum::ReadState'          => [qw(schema)],
    'GPForum::Service::Forum::ReadWorkflow'       => [qw(read_state)],
    'GPForum::Service::Forum::ThreadDetailReader' => [qw(schema)],
    'GPForum::Service::Forum::ThreadReader'       => [qw(schema)],
    'GPForum::Service::Forum::ThreadStore'        => [qw(schema)],
    'GPForum::Service::Forum::ViewerResolver'     => [qw(schema)],
);

sub _error_of ($code) {
    my $error;
    try {
        $code->();
    }
    catch ($caught) {
        $error = $caught;
    };

    return $error;
}

for my $class ( sort keys %REQUIRED ) {
    my @names = @{ $REQUIRED{$class} };
    ( my $file = "$class.pm" ) =~ s{::}{/}gmsx;
    require $file;

    ok( $class->isa('GPForum::Base'), "$class declares its collaborators" );
    is_deeply( [ sort $class->required_attributes ],
        \@names, "$class requires @names" );

    my $error = _error_of( sub { $class->new } );
    ok( GPForum::X::Argument->caught($error),
        "$class built without them is an argument error" );
    is(
        "$error",
        "$class requires " . join( q{, }, $class->required_attributes ),
        'naming every one it lacks'
    );

    # Each is only stored when the service is built, never called, so a
    # placeholder stands for it.
    my $built = _error_of(
        sub {
            $class->new( map { $_ => {} } @names );
        }
    );
    ok( !defined $built, "$class is built once it has them" );
}

done_testing();

1;
