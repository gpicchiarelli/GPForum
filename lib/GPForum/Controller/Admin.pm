# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Admin;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'GPForum::Controller::Admin::Base', -signatures;

our $VERSION = '0.001';

const my $HTTP_OK          => 200;
const my $HTTP_BAD_REQUEST => 400;

sub dashboard ($self) {
    my $user_id = $self->authorized_user_id( $self->admin_access->view_action );
    if ( !$user_id ) {
        return;
    }

    my $payload = eval { return $self->_dashboard_payload; };

    if ($EVAL_ERROR) {
        $self->app->log->error("admin dashboard failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload  => $payload,
            status   => $HTTP_OK,
            template => 'admin/dashboard',
        }
    );
}

sub roles ($self) {
    my $user_id = $self->authorized_user_id( $self->admin_access->view_action );
    if ( !$user_id ) {
        return;
    }

    my $payload = eval { return $self->_roles_payload; };

    if ($EVAL_ERROR) {
        $self->app->log->error("admin roles failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload  => $payload,
            status   => $HTTP_OK,
            template => 'admin/roles',
        }
    );
}

sub categories ($self) {
    my $user_id = $self->authorized_user_id( $self->admin_access->view_action );
    if ( !$user_id ) {
        return;
    }

    my $payload = eval { return $self->_categories_payload; };

    if ($EVAL_ERROR) {
        $self->app->log->error("admin categories failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload  => $payload,
            status   => $HTTP_OK,
            template => 'admin/categories',
        }
    );
}

sub user_roles ($self) {
    my $user_id = $self->authorized_user_id( $self->admin_access->view_action );
    if ( !$user_id ) {
        return;
    }

    my $target_user_id = $self->optional_param('user_id');
    if ( !$target_user_id ) {
        return $self->_bad_request( { user_id => 'user_id is required' } );
    }

    return $self->_render_user_roles($target_user_id);
}

sub audit ($self) {
    my $user_id = $self->authorized_user_id( $self->admin_access->view_action );
    if ( !$user_id ) {
        return;
    }

    # Checked before anything is queried: a value that is not a uuid would
    # make PostgreSQL reject the query on a uuid column, and a page filtered
    # by fewer filters than were asked for would mislead. Invalid input shows
    # the form with what was wrong, and no rows.
    my $review  = $self->gp_admin_audit_review;
    my $checked = $review->filters(
        {
            map { $_ => $self->optional_param($_) }
              qw(actor_id action target_type target_id correlation_id from until)
        }
    );
    my $invalid = %{ $checked->{errors} } ? 1              : 0;
    my $result  = $invalid                ? { rows => [] } : eval {
        return $review->page(
            $checked->{filters},
            {
                after => $self->optional_param('after'),
                limit => $self->limit_param
            }
        );
    };

    if ( !$result ) {
        $self->app->log->error("admin audit failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload => $self->gp_admin_view_model->audit_page(
                audit_rows  => $result->{rows},
                errors      => $checked->{errors},
                filters     => $checked->{filters},
                next_cursor => $result->{next_cursor},
            ),
            status   => $invalid ? $HTTP_BAD_REQUEST : $HTTP_OK,
            template => 'admin/audit',
        }
    );
}

sub users ($self) {
    my $user_id = $self->authorized_user_id( $self->admin_access->view_action );
    if ( !$user_id ) {
        return;
    }

    my $status = $self->optional_param('status');
    my $users  = eval {
        return $self->gp_admin_console_reader->list_users(
            {
                limit  => $self->limit_param,
                status => $status,
            }
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("admin users failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload => $self->gp_admin_view_model->users_page(
                status => $status,
                users  => $users,
            ),
            status   => $HTTP_OK,
            template => 'admin/users',
        }
    );
}

sub jobs ($self) {
    my $user_id = $self->authorized_user_id( $self->admin_access->view_action );
    if ( !$user_id ) {
        return;
    }

    my $status = $self->optional_param('status');
    my $jobs   = eval {
        return $self->gp_admin_console_reader->async_jobs(
            {
                limit  => $self->limit_param,
                status => $status,
            }
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("admin jobs failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload => $self->gp_admin_view_model->jobs_page(
                jobs        => $jobs,
                maintenance => {
                    cache_purge_command_id    => $self->_new_command_id,
                    search                    => $self->_search_status,
                    search_rebuild_command_id => $self->_new_command_id,
                },
                replay_command_ids => $self->_ids_for(
                    $jobs->{dead_letters} || [],
                    'dead_letter_id'
                ),
                status => $status,
            ),
            status   => $HTTP_OK,
            template => 'admin/jobs',
        }
    );
}

sub status ($self) {
    my $user_id = $self->authorized_user_id( $self->admin_access->view_action );
    if ( !$user_id ) {
        return;
    }

    my $status =
      eval { return $self->gp_admin_console_reader->operations_status; };

    if ($EVAL_ERROR) {
        $self->app->log->error("admin status failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload => $self->gp_admin_view_model->status_page(
                admin_status => $status
            ),
            status   => $HTTP_OK,
            template => 'admin/status',
        }
    );
}

sub _dashboard_payload ($self) {
    my $limit = $self->admin_access->dashboard_limit;
    my $console_summary =
      $self->gp_admin_console_reader->dashboard_summary( { limit => $limit } );

    return $self->gp_admin_view_model->dashboard(
        audit_rows =>
          $self->gp_admin_audit_review->recent( { limit => $limit } ),
        csrf_token => $self->csrf_token,
        roles      => $self->gp_role_catalog->list_roles( { limit => $limit } ),
        summary    => $console_summary,
    );
}

sub _roles_payload ($self) {
    my $limit = $self->limit_param;
    my $roles = $self->gp_role_catalog->list_roles( { limit => $limit } );

    return $self->gp_admin_view_model->roles_page(
        attach_command_ids    => $self->_ids_for( $roles, 'role_id' ),
        csrf_token            => $self->csrf_token,
        permission_command_id => $self->_new_command_id,
        permissions           =>
          $self->gp_role_catalog->list_permissions( { limit => $limit } ),
        role_command_id => $self->_new_command_id,
        roles           => $roles,
    );
}

sub _categories_payload ($self) {
    my $categories = $self->gp_category_store->list_categories(
        { limit => $self->limit_param } );

    return $self->gp_admin_view_model->categories_page(
        categories         => $categories,
        create_command_id  => $self->_new_command_id,
        csrf_token         => $self->csrf_token,
        update_command_ids => $self->_ids_for( $categories, 'category_id' ),
    );
}

sub _render_user_roles ( $self, $target_user_id ) {
    my $bindings = eval {
        return $self->gp_permission_review->roles_for_user( $target_user_id,
            { limit => $self->limit_param },
        );
    };

    if ($EVAL_ERROR) {
        $self->app->log->error("admin user roles failed: $EVAL_ERROR");
        return $self->system_failure;
    }

    return $self->render_payload(
        {
            payload => $self->gp_admin_view_model->user_roles_page(
                bindings           => $bindings,
                bind_command_id    => $self->_new_command_id,
                csrf_token         => $self->csrf_token,
                revoke_command_ids =>
                  $self->_ids_for( $bindings, 'binding_id' ),
                user_id => $target_user_id,
            ),
            status   => $HTTP_OK,
            template => 'admin/user_roles',
        }
    );
}

sub _ids_for ( $self, $rows, $key ) {
    my %ids;
    for my $row ( @{$rows} ) {
        my $id = $row->{$key};
        if ($id) {
            $ids{$id} = $self->_new_command_id;
        }
    }

    return \%ids;
}

# Search's lag and last rebuild, for the jobs page. A failure to read them
# leaves the section saying so rather than failing the page.
sub _search_status ($self) {
    my $search = eval { return $self->gp_admin_maintenance->search_status };
    if ($EVAL_ERROR) {
        $self->app->log->warn("admin search status failed: $EVAL_ERROR");
        return { unavailable => 1 };
    }

    return $search;
}

sub _new_command_id ($self) {
    return $self->gp_id->uuid;
}

1;

__END__

=head1 NAME

GPForum::Controller::Admin - Admin review pages.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    $routes->get('/admin')->to('Admin#dashboard');

=head1 DESCRIPTION

Renders authorized dashboard, role, category, user, audit, job, and status
review pages.
The catalog C<view> action lives on L<GPForum::Web::AdminAccess>. Dashboard
failures stay logged here.

=head1 SUBROUTINES/METHODS

=head2 dashboard

Renders the admin dashboard.

=head2 roles

Renders the role and permission catalog.

=head2 categories

Renders the category catalog.

=head2 user_roles

Renders role bindings for a user.

=head2 audit

Renders recent or target-filtered audit rows.

=head2 users

Renders the admin user list.

=head2 jobs

Renders outbox and dead-letter job lists.

=head2 status

Renders operations status.

=head1 DIAGNOSTICS

Unauthorized, forbidden, and reader failures use the shared admin helpers.

=head1 CONFIGURATION AND ENVIRONMENT

Uses admin reader helpers configured during application startup.

=head1 DEPENDENCIES

Uses L<GPForum::Controller::Admin::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Write commands live in sibling catalog, category, and binding controllers.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
