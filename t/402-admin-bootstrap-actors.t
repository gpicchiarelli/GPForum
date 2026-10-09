# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Admin::Bootstrapper;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

# Who the bootstrap writes as, and what a second bootstrap answers. Every
# row it creates -- the role, each permission and its attachment, the
# binding -- is audited under the operator who ran it, or under the member
# being made owner when no operator is named. A second run finds the rows
# the first created and reports them with their ids.
my $named = _bootstrapper();
my $first = $named->{bootstrapper}
  ->bootstrap( { actor_user_id => 'operator-1', user_id => 'user-1' } );
is_deeply( _audit_actors($named), ['operator-1'],
    'every audit row of the bootstrap names the operator' );
is( $first->{binding}{created_by_user_id},
    'operator-1', 'and the binding is created by the operator' );

my $again = $named->{bootstrapper}
  ->bootstrap( { actor_user_id => 'operator-1', user_id => 'user-1' } );
is_deeply(
    [
        @{ $again->{binding} }
          {qw(binding_id role_id user_id created_by_user_id)}
    ],
    [
        @{ $first->{binding} }
          {qw(binding_id role_id user_id created_by_user_id)}
    ],
    'a second bootstrap reports the binding the first created'
);
is( $again->{role}{role_id}, $first->{role}{role_id}, 'and its role' );
is_deeply(
    [ map { $_->{permission}{permission_id} } @{ $again->{permissions} } ],
    [ map { $_->{permission}{permission_id} } @{ $first->{permissions} } ],
    'and each of its permissions'
);

my $unnamed = _bootstrapper();
my $owner   = $unnamed->{bootstrapper}->bootstrap( { user_id => 'user-2' } );
is_deeply( _audit_actors($unnamed), ['user-2'],
    'without an operator every audit row names the new owner' );
is( $owner->{binding}{created_by_user_id}, 'user-2', 'as does the binding' );

done_testing();

sub _bootstrapper {
    my %resultsets =
      map {
        $_ => GPForum::Test::ModerationResultSet->new( filter_search => 1 )
      } qw(AuditLog Permission Role RoleBinding RolePermission);

    return {
        audit_log    => $resultsets{AuditLog},
        bootstrapper => GPForum::Service::Admin::Bootstrapper->new(
            clock      => GPForum::Test::FixedClock->new,
            id_service => GPForum::Test::Id->new,
            schema     => GPForum::Test::ModerationSchema->new(
                resultsets => \%resultsets
            ),
        ),
    };
}

# The distinct actors of the audit rows written so far.
sub _audit_actors {
    my ($fixtures) = @_;

    my %actors = map { ( $_->{actor_id} // 'none' ) => 1 }
      @{ $fixtures->{audit_log}->created };

    return [ sort keys %actors ];
}

1;
