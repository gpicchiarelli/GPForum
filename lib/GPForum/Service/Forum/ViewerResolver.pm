# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Forum::ViewerResolver;

use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use GPForum::Infrastructure::CountedQuery;
use GPForum::Infrastructure::Id;
use GPForum::Service::Forum::Viewer;

our $VERSION = '0.001';

# Only an active account is a member. A pending one has not confirmed its
# e-mail: it cannot sign in (Identity::AuthStore), and confirming makes it
# active, so a session for it is an anomaly and reads what an anonymous
# visitor reads. It used to count as a member, on the premise -- true once,
# no longer -- that verification never moved an account to active.
const my %MEMBER_STATUS => ( active => 1 );

# One statement per request: the account's status, whether a suspension is in
# force, and the scopes of its category.read grants (ADR 0102, Viewers). A
# global grant has neither a resource nor a space; a space grant names the
# space; a category grant names the category.
const my $VIEWER_SQL => join q{ },
  'SELECT u.status,',
  'EXISTS (SELECT 1 FROM suspensions s WHERE s.user_id = u.id',
  'AND s.revoked_at IS NULL AND s.valid_from <= now()',
  'AND (s.valid_to IS NULL OR s.valid_to > now())) AS suspended,',
  q{COALESCE((SELECT json_agg(json_build_object('resource_type',},
  q{b.resource_type, 'resource_id', b.resource_id, 'space_id', b.space_id))},
  'FROM role_bindings b',
  'JOIN role_permissions rp ON rp.role_id = b.role_id',
  'JOIN permissions p ON p.permission_id = rp.permission_id',
  'WHERE b.user_id = u.id AND b.revoked_at IS NULL',
  q{AND p.resource_type = 'category' AND p.action = 'read'), '[]') AS grants},
  'FROM users u WHERE u.id = ?';

__PACKAGE__->requires('schema');

has logger => undef;    # optional: without it nothing is logged

# Fails closed: without a readable account -- none, suspended, deleted, or a
# resolution that errors -- the viewer reads what an anonymous reader does,
# keeping only the user id so an author still reaches their own threads.
sub resolve ( $self, $user_id ) {
    my $viewer_class = 'GPForum::Service::Forum::Viewer';

    # No account row can match an id that is not a uuid, so none is read: the
    # viewer is a non-member keeping the id, which reads public content only.
    return $viewer_class->from($user_id)
      if !GPForum::Infrastructure::Id->is_uuid($user_id);

    my $row;
    try { $row = $self->_viewer_row($user_id); }
    catch ($error) {
        $self->_warn("viewer resolution degraded: $error");
    };
    return $viewer_class->new( user_id => $user_id ) if !$row;

    my $member = exists $MEMBER_STATUS{ $row->{status} // q{} }
      && !$row->{suspended} ? 1 : 0;
    return $viewer_class->new( user_id => $user_id ) if !$member;

    return $viewer_class->new(
        member  => 1,
        user_id => $user_id,
        %{ $self->grant_scopes( $row->{grants} ) },
    );
}

sub _viewer_row ( $self, $user_id ) {
    return GPForum::Infrastructure::CountedQuery->select_row( $self->schema,
        $VIEWER_SQL, $user_id );
}

# The scopes a list of role bindings grants (decoded or as JSON). Public so
# the mapping is tested on its own, without an account in a database.
sub grant_scopes ( $class, $json ) {
    my $grants = ref $json ? $json : decode_json( $json // '[]' );
    my %scopes = ( category_ids => [], global_read => 0, space_ids => [] );

    # Exactly three shapes grant, and every other grants nothing: a global
    # binding (no resource, no space), a space binding (the space), and a
    # category binding (the category). The review of stage 1 found that
    # reading anything with a space as a space-wide grant widened, say, a
    # thread-scoped binding to its whole space.
    for my $grant ( @{$grants} ) {
        my $type = $grant->{resource_type} // q{};
        if (   $type eq 'global'
            && !defined $grant->{resource_id}
            && !defined $grant->{space_id} )
        {
            $scopes{global_read} = 1;
        }
        elsif ( $type eq 'category' && defined $grant->{resource_id} ) {
            push @{ $scopes{category_ids} }, $grant->{resource_id};
        }
        elsif ( $type eq 'space'
            && defined( my $space = $grant->{resource_id}
                  // $grant->{space_id} ) )
        {
            push @{ $scopes{space_ids} }, $space;
        }
    }

    return \%scopes;
}

sub _warn ( $self, $message ) {
    if ( $self->logger ) {
        $self->logger->warn($message);
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Forum::ViewerResolver - Resolve the reader of a request.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $viewer = $resolver->resolve( $session_user_id );

=head1 DESCRIPTION

Turns a session user id into a L<GPForum::Service::Forum::Viewer> with one
query: the account's status, an active suspension, and the scopes of its
C<category.read> grants (ADR 0102). Pending accounts count as members;
suspended and deleted ones do not.

=head1 SUBROUTINES/METHODS

=head2 new

Constructor (L<GPForum::Base>). C<schema>, the L<DBIx::Class> schema, is
required: without it C<new> throws L<GPForum::X::Argument>. C<logger> is
optional; without it a degraded resolution is not logged.

=head2 resolve

Returns the viewer; anonymous for no user, and anonymous-equivalent (the user
id kept for authorship) when the account cannot read or resolution fails.

=head2 grant_scopes

Returns C<global_read>, C<space_ids> and C<category_ids> for a list of
C<category.read> role bindings: a global binding with no resource and no
space, a space binding, and a category binding grant; any other shape grants
nothing.

=head1 DIAGNOSTICS

Logs a warning when resolution fails.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Forum::Viewer>, L<JSON::MaybeXS>, L<GPForum::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
