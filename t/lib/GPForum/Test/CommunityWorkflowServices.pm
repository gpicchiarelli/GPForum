package GPForum::Test::CommunityWorkflowServices;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

our $VERSION = '0.001';

has bookmark_saves       => sub { return []; };
has bookmark_removes     => sub { return []; };
has report_creates       => sub { return []; };
has subscription_saves   => sub { return []; };
has subscription_mutes   => sub { return []; };
has subscription_revokes => sub { return []; };

sub save_bookmark {
    my ( $self, $input ) = @_;

    _maybe_boom( $input, 'bookmark store down' );
    push @{ $self->bookmark_saves }, $input;

    return {
        bookmark_id => 'bookmark-1',
        created_at  => '2026-05-23T12:00:00Z',
        deleted_at  => undef,
        note        => $input->{note} || q{},
        target_id   => $input->{target_id},
        target_type => $input->{target_type},
        user_id     => $input->{user_id},
    };
}

sub remove_for_user_target {
    my ( $self, $input ) = @_;

    _maybe_boom( $input, 'bookmark store down' );
    if ( _is_gone($input) ) {
        return { error => 'not_found', ok => 0 };
    }

    push @{ $self->bookmark_removes }, $input;

    return {
        bookmark_id => 'bookmark-1',
        deleted_at  => '2026-05-23T12:00:00Z',
        ok          => 1,
        target_id   => $input->{target_id},
        target_type => $input->{target_type},
        user_id     => $input->{user_id},
    };
}

sub save_subscription {
    my ( $self, $input ) = @_;

    _maybe_boom( $input, 'subscription store down' );
    push @{ $self->subscription_saves }, $input;

    return {
        created_at      => '2026-05-23T12:00:00Z',
        muted_at        => undef,
        preference      => $input->{preference} || 'all',
        revoked_at      => undef,
        subscription_id => 'subscription-1',
        target_id       => $input->{target_id},
        target_type     => $input->{target_type},
        user_id         => $input->{user_id},
    };
}

sub mute_for_user_target {
    my ( $self, $input ) = @_;

    _maybe_boom( $input, 'subscription store down' );
    if ( _is_gone($input) ) {
        return { error => 'not_found', ok => 0 };
    }

    push @{ $self->subscription_mutes }, $input;

    return {
        muted_at        => '2026-05-23T12:00:00Z',
        ok              => 1,
        subscription_id => 'subscription-1',
        target_id       => $input->{target_id},
        user_id         => $input->{user_id},
    };
}

sub revoke_for_user_target {
    my ( $self, $input ) = @_;

    _maybe_boom( $input, 'subscription store down' );
    if ( _is_gone($input) ) {
        return { error => 'not_found', ok => 0 };
    }

    push @{ $self->subscription_revokes }, $input;

    return {
        ok              => 1,
        revoked_at      => '2026-05-23T12:00:00Z',
        subscription_id => 'subscription-1',
        target_id       => $input->{target_id},
        user_id         => $input->{user_id},
    };
}

sub create_report {
    my ( $self, $input ) = @_;

    _maybe_report_boom( $input, 'report store down' );
    push @{ $self->report_creates }, $input;

    return {
        created_at       => '2026-05-23T12:00:00Z',
        details          => $input->{details} || q{},
        reason           => $input->{reason},
        report_id        => 'report-1',
        reporter_user_id => $input->{reporter_user_id},
        status           => 'open',
        target_id        => $input->{target_id},
        target_type      => $input->{target_type},
    };
}

sub _maybe_boom {
    my ( $input, $message ) = @_;

    if ( ( $input->{user_id} || q{} ) eq 'boom' ) {
        croak $message;
    }

    return;
}

sub _is_gone {
    my ($input) = @_;

    return ( $input->{user_id} || q{} ) eq 'gone' ? 1 : 0;
}

sub _maybe_report_boom {
    my ( $input, $message ) = @_;

    if ( ( $input->{reporter_user_id} || q{} ) eq 'boom' ) {
        croak $message;
    }

    return;
}

1;

__END__

=head1 NAME

GPForum::Test::CommunityWorkflowServices - Bookmark and subscription fakes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $services = GPForum::Test::CommunityWorkflowServices->new;

=head1 DESCRIPTION

Test double for C<Community::Workflow> bookmark, subscription, and report
outcomes: success, missing row, and store exceptions.

=head1 SUBROUTINES/METHODS

=head2 save_bookmark

Records a bookmark write or throws for C<boom>.

=head2 remove_for_user_target

Records a bookmark remove, maps C<gone> to missing, or throws.

=head2 save_subscription

Records a subscription write or throws for C<boom>.

=head2 mute_for_user_target

Records a mute, maps C<gone> to missing, or throws.

=head2 revoke_for_user_target

Records a revoke, maps C<gone> to missing, or throws.

=head2 create_report

Records a report write or throws for C<boom>.

=head1 DIAGNOSTICS

The C<boom> user id throws. The C<gone> user id is missing. The C<boom>
reporter id throws on C<create_report>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Intended only for workflow unit tests.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
