# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use English qw(-no_match_vars);
use Test::More;

use lib 'lib';

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Service::Admin::RoleBindingStore;

our $VERSION = '0.001';

my $false_attempts = 0;

package Local::Row;

use Mojo::Base -base;

has columns => sub { return {}; };

sub get_column {
    my ( $self, $name ) = @_;

    return $self->columns->{$name};
}

sub update {
    my ( $self, $changes ) = @_;

    @{ $self->columns }{ keys %{$changes} } = values %{$changes};

    return $self;
}

package Local::Search;

use Mojo::Base -base;

has matched => sub { return []; };

sub single {
    my ($self) = @_;

    return $self->matched->[0];
}

package Local::ResultSet;

use Mojo::Base -base;

has name   => undef;
has schema => undef;

my %ID_COLUMN = (
    AuditLog    => 'audit_id',
    RoleBinding => 'binding_id',
);

sub create {
    my ( $self, $row ) = @_;

    push @{ $self->schema->created_for( $self->name ) }, $row;
    my $stored = Local::Row->new( columns => { %{$row} } );
    push @{ $self->schema->rows_for( $self->name ) }, $stored;

    return $stored;
}

sub find {
    my ( $self, $id ) = @_;

    my $column = $ID_COLUMN{ $self->name };
    my $undefined;
    return $undefined if !$column;

    return $self->search( { $column => $id } )->single;
}

# DBIx::Class's context-proof form of search, which lib/ now calls.
sub search_rs {
    my ( $self, @arguments ) = @_;

    return $self->search(@arguments);
}

sub search {
    my ( $self, $where ) = @_;

    my $rows    = $self->schema->rows_for( $self->name );
    my @matched = grep { _matches( $_, $where ) } @{$rows};

    return Local::Search->new( matched => \@matched );
}

sub _matches {
    my ( $row, $where ) = @_;

    for my $column ( keys %{$where} ) {
        my $matched =
          _matches_column( $row->get_column($column), $where->{$column} );
        return 0 if !$matched;
    }

    return 1;
}

sub _matches_column {
    my ( $actual, $wanted ) = @_;

    if ( !defined $wanted ) {
        return !defined $actual;
    }
    if ( !defined $actual ) {
        return 0;
    }

    return $actual eq $wanted;
}

package Local::PlainSchema;

use Mojo::Base -base;

has created => sub { return {}; };
has rows    => sub { return {}; };

sub resultset {
    my ( $self, $name ) = @_;

    return Local::ResultSet->new( name => $name, schema => $self );
}

sub created_for {
    my ( $self, $name ) = @_;

    $self->created->{$name} ||= [];

    return $self->created->{$name};
}

sub rows_for {
    my ( $self, $name ) = @_;

    $self->rows->{$name} ||= [];

    return $self->rows->{$name};
}

package Local::Schema;

use Mojo::Base 'Local::PlainSchema';

has transactions => 0;

sub txn_do {
    my ( $self, $code ) = @_;

    $self->transactions( $self->transactions + 1 );

    return $code->();
}

package Local::Recorder;

use Mojo::Base -base;

has audits => sub { return []; };

sub record_audit {
    my ( $self, %input ) = @_;

    push @{ $self->audits }, \%input;

    return \%input;
}

package Local::FalseRetryStore;

use Mojo::Base 'GPForum::Service::Admin::RoleBindingStore';

sub _create_binding {
    $false_attempts = $false_attempts + 1;
    if ( $false_attempts == 1 ) {
        GPForum::Infrastructure::UniqueConflict->throw('role_bindings_pkey');
    }

    return 0;
}

package Local::FailingStore;

use Carp qw(croak);
use Mojo::Base 'GPForum::Service::Admin::RoleBindingStore';

sub _create_binding {
    croak 'role binding store offline';
}

package main;

my %BINDING_INPUT = (
    actor_user_id => 'actor-1',
    resource_id   => 'space-1',
    resource_type => 'space',
    role_id       => 'role-1',
    space_id      => 'space-1',
    user_id       => 'user-1',
);

my $schema   = Local::Schema->new;
my $recorder = Local::Recorder->new;
my $store    = GPForum::Service::Admin::RoleBindingStore->new(
    recorder => $recorder,
    schema   => $schema,
);

my $bound = $store->bind_role( {%BINDING_INPUT} );
ok( $bound->{ok}, 'bind_role stores a new binding' );
is( $schema->transactions, 1,
    'bind_role wraps the binding and audit writes in one transaction' );
is( scalar @{ $schema->created_for('RoleBinding') },
    1, 'the role binding row is written inside the transaction' );
is( scalar @{ $recorder->audits },
    1, 'the creation audit is recorded inside the same transaction' );

my $binding_id = $bound->{binding}{binding_id};
my $revoked    = $store->revoke_binding( $binding_id, 'actor-2' );
is( $revoked->{binding_id}, $binding_id, 'revoke_binding reports the binding' );
is( $schema->transactions, 2,
    'revoke_binding wraps the update and audit writes in one transaction' );
is( scalar @{ $recorder->audits },
    2, 'the revocation audit is recorded inside the same transaction' );

my $plain_store = GPForum::Service::Admin::RoleBindingStore->new(
    recorder => Local::Recorder->new,
    schema   => Local::PlainSchema->new,
);
ok(
    $plain_store->bind_role( {%BINDING_INPUT} )->{ok},
    'bind_role still writes through a schema without txn_do'
);

# A false insert result is not an exception: the retry must not rethrow a
# stale evaluation error when the insert simply returns something false.
my $false_store = Local::FalseRetryStore->new(
    recorder => Local::Recorder->new,
    schema   => Local::Schema->new,
);
my $false_result = eval { return $false_store->bind_role( {%BINDING_INPUT} ); };
is( $EVAL_ERROR, q{},
    'a false insert result does not rethrow a stale evaluation error' );
ok( !$false_result, 'the false insert result is returned to the caller' );
is( $false_attempts, 2, 'the id conflict triggered exactly one retry' );

# A thrown error must still propagate, driven by the evaluation error.
my $failing_store = Local::FailingStore->new(
    recorder => Local::Recorder->new,
    schema   => Local::Schema->new,
);
my $failed = eval { return $failing_store->bind_role( {%BINDING_INPUT} ); };
like(
    $EVAL_ERROR,
    qr/role [ ] binding [ ] store [ ] offline/msx,
    'a thrown insert error still propagates to the caller'
);
ok( !defined $failed, 'nothing is returned when the insert throws' );

done_testing();

1;
