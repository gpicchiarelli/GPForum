# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ModerationResultSet;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::Query;

use GPForum::Infrastructure::UniqueConflict;
use GPForum::Test::ModerationRow;
use GPForum::Test::ModerationSearch;

our $VERSION = '0.001';

has created         => sub { return []; };
has created_objects => sub { return []; };
has find_misses     => 0;
has rows            => sub { return {}; };
has last_query      => sub { return {}; };
has last_attrs      => sub { return {}; };
has filter_search   => 0;
has schema          => undef;
has skip_search     => 0;

sub create {
    my ( $self, $row ) = @_;

    $self->_assert_usable;
    $self->_assert_unique_row($row);
    my $object = GPForum::Test::ModerationRow->new( data => $row );
    push @{ $self->created },         $row;
    push @{ $self->created_objects }, $object;
    $self->_store_row( $row, $object );

    return $object;
}

sub update_or_create {
    my ( $self, $row ) = @_;

    return $self->create($row);
}

sub find {
    my ( $self, $query ) = @_;

    $self->_assert_usable;
    if ( $self->find_misses ) {
        $self->find_misses( $self->find_misses - 1 );
        return;
    }

    my $key = ref $query eq 'HASH' ? _find_key($query) : $query;

    return $self->rows->{$key};
}

# DBIx::Class's context-proof form of search. lib/ calls it wherever it means a
# resultset, because search itself returns every row in list context.
sub search_rs {
    my ( $self, @arguments ) = @_;

    return $self->search(@arguments);
}

sub search {
    my ( $self, $query, $attrs ) = @_;

    $self->_assert_usable;
    $self->last_query($query);
    $self->last_attrs( $attrs || {} );

    my $skipped = $self->_skipped_search;
    if ($skipped) {
        return $skipped;
    }

    return $self->_filtered_search( $query, $attrs );
}

sub _filtered_search {
    my ( $self, $query, $attrs ) = @_;

    my @rows = $self->_candidate_rows;
    if ( $self->filter_search || _should_filter($query) ) {
        @rows = grep { _matches_query( $_, $query ) } @rows;
    }
    @rows =
      GPForum::Test::Query::ordered_rows( \@rows, $attrs, \&_read_column );
    @rows = GPForum::Test::Query::windowed_rows( \@rows, $attrs );

    return GPForum::Test::ModerationSearch->new( rows => \@rows );
}

sub _candidate_rows {
    my ($self) = @_;

    my @source =
        @{ $self->created_objects }
      ? @{ $self->created_objects }
      : values %{ $self->rows };
    my %seen;

    return grep { !$seen{ 0 + $_ }++ } @source;
}

sub _skipped_search {
    my ($self) = @_;

    if ( !$self->skip_search ) {
        return;
    }

    $self->skip_search( $self->skip_search - 1 );

    return GPForum::Test::ModerationSearch->new( rows => [] );
}

# A unique violation is what puts a real transaction into the aborted state.
# Marking it here is what makes the double able to fail a recovery path that
# would be unreachable against PostgreSQL.
sub _assert_unique_row {
    my ( $self, $row ) = @_;

    my $ok = eval {
        $self->_run_unique_row($row);
        1;
    };
    if ( !$ok ) {
        my $failure = $@;
        $self->_mark_aborted;
        die $failure;    ## no critic (ErrorHandling::RequireCarping)
    }

    return;
}

sub _assert_usable {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( $schema && $schema->can('assert_transaction_usable') ) {
        $schema->assert_transaction_usable;
    }

    return;
}

sub _mark_aborted {
    my ($self) = @_;

    my $schema = $self->schema;
    if ( $schema && $schema->can('mark_transaction_aborted') ) {
        $schema->mark_transaction_aborted;
    }

    return;
}

sub _run_unique_row {
    my ( $self, $row ) = @_;

    $self->_assert_report_id_unique($row);
    $self->_assert_open_report_unique($row);
    $self->_assert_action_id_unique($row);
    $self->_assert_command_unique($row);
    $self->_assert_suspension_id_unique($row);
    $self->_assert_deletion_id_unique($row);
    $self->_assert_open_deletion_unique($row);
    $self->_assert_deletion_action_id_unique($row);
    $self->_assert_export_id_unique($row);
    $self->_assert_pending_export_unique($row);
    $self->_assert_hold_id_unique($row);
    $self->_assert_active_hold_unique($row);
    $self->_assert_erasure_id_unique($row);
    $self->_assert_erasure_job_unique($row);
    $self->_assert_plugin_id_unique($row);
    $self->_assert_plugin_unique($row);
    $self->_assert_plugin_hook_id_unique($row);
    $self->_assert_plugin_hook_unique($row);
    $self->_assert_plugin_failure_id_unique($row);
    $self->_assert_role_id_unique($row);
    $self->_assert_role_unique($row);
    $self->_assert_permission_id_unique($row);
    $self->_assert_permission_unique($row);
    $self->_assert_role_permission_unique($row);
    $self->_assert_category_id_unique($row);
    $self->_assert_category_unique($row);
    $self->_assert_legacy_map_id_unique($row);
    $self->_assert_legacy_map_unique($row);
    $self->_assert_import_job_id_unique($row);
    $self->_assert_import_failure_id_unique($row);
    $self->_assert_import_failure_unique($row);
    $self->_assert_space_id_unique($row);
    $self->_assert_space_unique($row);
    $self->_assert_binding_id_unique($row);
    $self->_assert_role_binding_unique($row);

    return;
}

sub _assert_report_id_unique {
    my ( $self, $row ) = @_;

    if ( !_report_identity_row($row) ) {
        return;
    }
    if ( _report_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('reports_pkey');
    }

    return;
}

sub _report_id_taken {
    my ( $self, $row ) = @_;

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_report_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_report_id {
    my ( $existing, $row ) = @_;

    if ( !_report_identity_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{report_id}, $row->{report_id} );
}

sub _report_identity_row {
    my ($row) = @_;

    if ( !_has_text( $row->{report_id} ) ) {
        return 0;
    }
    if ( _has_text( $row->{moderation_action_id} ) ) {
        return 0;
    }

    return _has_text( $row->{reporter_user_id} );
}

sub _assert_open_report_unique {
    my ( $self, $row ) = @_;

    if ( !$row->{report_id} || !_open_status( $row->{status} ) ) {
        return;
    }

    for my $existing ( @{ $self->created } ) {
        if ( _same_open_report( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_reports_reporter_target_open_unique');
        }
    }

    return;
}

sub _assert_action_id_unique {
    my ( $self, $row ) = @_;

    if ( !_action_identity_row($row) ) {
        return;
    }
    if ( _action_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'moderation_actions_pkey');
    }

    return;
}

sub _action_id_taken {
    my ( $self, $row ) = @_;

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_action_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_action_id {
    my ( $existing, $row ) = @_;

    if ( !_action_identity_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{moderation_action_id},
        $row->{moderation_action_id} );
}

sub _action_identity_row {
    my ($row) = @_;

    if ( !_has_text( $row->{moderation_action_id} ) ) {
        return 0;
    }

    return _has_text( $row->{action_type} );
}

sub _assert_command_unique {
    my ( $self, $row ) = @_;

    if ( !_action_identity_row($row) ) {
        return;
    }

    my $command_id = $row->{command_id};
    if ( !defined $command_id || !length $command_id ) {
        return;
    }
    if ( $self->_command_id_taken($command_id) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'idx_moderation_actions_command_id');
    }

    return;
}

sub _command_id_taken {
    my ( $self, $command_id ) = @_;

    for my $existing ( @{ $self->created } ) {
        if ( _same_text( $existing->{command_id}, $command_id ) ) {
            return 1;
        }
    }

    return 0;
}

sub _assert_suspension_id_unique {
    my ( $self, $row ) = @_;

    if ( !_suspension_identity_row($row) ) {
        return;
    }
    if ( _suspension_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('suspensions_pkey');
    }

    return;
}

sub _suspension_id_taken {
    my ( $self, $row ) = @_;

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_suspension_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_suspension_id {
    my ( $existing, $row ) = @_;

    if ( !_suspension_identity_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{suspension_id}, $row->{suspension_id} );
}

sub _suspension_identity_row {
    my ($row) = @_;

    if ( !_has_text( $row->{suspension_id} ) ) {
        return 0;
    }
    if ( _has_text( $row->{moderation_action_id} ) ) {
        return 0;
    }

    return _has_text( $row->{reason} );
}

sub _assert_deletion_id_unique {
    my ( $self, $row ) = @_;

    if ( !_deletion_identity_row($row) ) {
        return;
    }
    if ( _deletion_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'deletion_requests_pkey');
    }

    return;
}

sub _deletion_id_taken {
    my ( $self, $row ) = @_;

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_deletion_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_deletion_id {
    my ( $existing, $row ) = @_;

    if ( !_deletion_identity_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{deletion_request_id},
        $row->{deletion_request_id} );
}

sub _deletion_identity_row {
    my ($row) = @_;

    if ( !_has_text( $row->{deletion_request_id} ) ) {
        return 0;
    }
    if ( _has_text( $row->{erasure_job_id} ) ) {
        return 0;
    }
    if ( _has_text( $row->{deletion_action_id} ) ) {
        return 0;
    }

    return _has_text( $row->{resource_type} );
}

sub _assert_open_deletion_unique {
    my ( $self, $row ) = @_;

    if ( !_open_deletion_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_open_deletion( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_deletion_requests_open_resource_unique');
        }
    }

    return;
}

sub _assert_deletion_action_id_unique {
    my ( $self, $row ) = @_;

    if ( !_deletion_action_identity_row($row) ) {
        return;
    }
    if ( _deletion_action_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('deletion_actions_pkey');
    }

    return;
}

sub _deletion_action_id_taken {
    my ( $self, $row ) = @_;

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_deletion_action_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_deletion_action_id {
    my ( $existing, $row ) = @_;

    if ( !_deletion_action_identity_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{deletion_action_id},
        $row->{deletion_action_id} );
}

sub _deletion_action_identity_row {
    my ($row) = @_;

    if ( !_has_text( $row->{deletion_action_id} ) ) {
        return 0;
    }

    return _has_text( $row->{action_type} );
}

sub _assert_export_id_unique {
    my ( $self, $row ) = @_;

    if ( !_export_identity_row($row) ) {
        return;
    }
    if ( _export_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('export_requests_pkey');
    }

    return;
}

sub _export_id_taken {
    my ( $self, $row ) = @_;

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_export_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_export_id {
    my ( $existing, $row ) = @_;

    if ( !_export_identity_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{export_request_id},
        $row->{export_request_id} );
}

sub _export_identity_row {
    my ($row) = @_;

    if ( !_has_text( $row->{export_request_id} ) ) {
        return 0;
    }

    return _has_text( $row->{requester_user_id} );
}

sub _assert_pending_export_unique {
    my ( $self, $row ) = @_;

    if ( !_pending_export_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_pending_export( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_export_requests_pending_unique');
        }
    }

    return;
}

sub _assert_hold_id_unique {
    my ( $self, $row ) = @_;

    if ( !_hold_identity_row($row) ) {
        return;
    }
    if ( _hold_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('retention_holds_pkey');
    }

    return;
}

sub _hold_id_taken {
    my ( $self, $row ) = @_;

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_hold_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_hold_id {
    my ( $existing, $row ) = @_;

    if ( !_hold_identity_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{retention_hold_id},
        $row->{retention_hold_id} );
}

sub _hold_identity_row {
    my ($row) = @_;

    if ( !_has_text( $row->{retention_hold_id} ) ) {
        return 0;
    }
    if ( _has_text( $row->{deletion_request_id} ) ) {
        return 0;
    }

    return _has_text( $row->{resource_type} );
}

sub _assert_active_hold_unique {
    my ( $self, $row ) = @_;

    if ( !_active_hold_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_active_hold( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_retention_holds_active_resource_unique');
        }
    }

    return;
}

sub _assert_erasure_id_unique {
    my ( $self, $row ) = @_;

    if ( !_erasure_job_row($row) ) {
        return;
    }
    if ( _erasure_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('erasure_jobs_pkey');
    }

    return;
}

sub _erasure_id_taken {
    my ( $self, $row ) = @_;

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_erasure_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_erasure_id {
    my ( $existing, $row ) = @_;

    if ( !_erasure_job_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{erasure_job_id}, $row->{erasure_job_id} );
}

sub _assert_erasure_job_unique {
    my ( $self, $row ) = @_;

    if ( !_erasure_job_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_erasure_request( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_erasure_jobs_request_unique');
        }
    }

    return;
}

sub _live_created_rows {
    my ($self) = @_;

    if ( @{ $self->created_objects } ) {
        return map { $_->data } @{ $self->created_objects };
    }

    return @{ $self->created };
}

sub _active_hold_row {
    my ($row) = @_;

    if ( !_has_text( $row->{retention_hold_id} ) ) {
        return 0;
    }

    return _hold_is_active($row);
}

sub _same_active_hold {
    my ( $existing, $row ) = @_;

    if ( !_hold_is_active($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{resource_type}, $row->{resource_type} ) ) {
        return 0;
    }

    return _same_text( $existing->{resource_id}, $row->{resource_id} );
}

sub _hold_is_active {
    my ($row) = @_;

    if ( defined $row->{ends_at} ) {
        return 0;
    }

    return 1;
}

sub _erasure_job_row {
    my ($row) = @_;

    if ( !_has_text( $row->{erasure_job_id} ) ) {
        return 0;
    }

    return _has_text( $row->{deletion_request_id} );
}

sub _same_erasure_request {
    my ( $existing, $row ) = @_;

    if ( !_erasure_job_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{deletion_request_id},
        $row->{deletion_request_id} );
}

sub _assert_plugin_id_unique {
    my ( $self, $row ) = @_;

    if ( !_plugin_identity_row($row) ) {
        return;
    }
    if ( _plugin_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('plugins_pkey');
    }

    return;
}

sub _assert_plugin_unique {
    my ( $self, $row ) = @_;

    if ( !_plugin_identity_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_plugin_identity( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'plugins_name_version_key');
        }
    }

    return;
}

sub _plugin_id_taken {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{plugin_id} ) ) {
        return 0;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_text( $existing->{plugin_id}, $row->{plugin_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _plugin_identity_row {
    my ($row) = @_;

    if ( !_has_text( $row->{plugin_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{name} ) ) {
        return 0;
    }

    return _has_text( $row->{version} );
}

sub _same_plugin_identity {
    my ( $existing, $row ) = @_;

    if ( !_plugin_identity_row($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{name}, $row->{name} ) ) {
        return 0;
    }

    return _same_text( $existing->{version}, $row->{version} );
}

sub _assert_plugin_hook_id_unique {
    my ( $self, $row ) = @_;

    if ( !_plugin_hook_row($row) ) {
        return;
    }
    if ( _hook_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('plugin_hooks_pkey');
    }

    return;
}

sub _hook_id_taken {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{hook_id} ) ) {
        return 0;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_text( $existing->{hook_id}, $row->{hook_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _assert_plugin_hook_unique {
    my ( $self, $row ) = @_;

    if ( !_plugin_hook_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_plugin_hook( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_plugin_hooks_plugin_name_unique');
        }
    }

    return;
}

sub _plugin_hook_row {
    my ($row) = @_;

    if ( !_has_text( $row->{hook_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{plugin_id} ) ) {
        return 0;
    }
    if ( _has_text( $row->{plugin_failure_id} ) ) {
        return 0;
    }

    return _has_text( $row->{hook_name} );
}

sub _same_plugin_hook {
    my ( $existing, $row ) = @_;

    if ( !_plugin_hook_row($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{plugin_id}, $row->{plugin_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{hook_name}, $row->{hook_name} );
}

sub _assert_plugin_failure_id_unique {
    my ( $self, $row ) = @_;

    if ( !_plugin_failure_identity_row($row) ) {
        return;
    }
    if ( _plugin_failure_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('plugin_failures_pkey');
    }

    return;
}

sub _plugin_failure_id_taken {
    my ( $self, $row ) = @_;

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_plugin_failure_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_plugin_failure_id {
    my ( $existing, $row ) = @_;

    if ( !_plugin_failure_identity_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{plugin_failure_id},
        $row->{plugin_failure_id} );
}

sub _plugin_failure_identity_row {
    my ($row) = @_;

    if ( !_has_text( $row->{plugin_failure_id} ) ) {
        return 0;
    }
    if ( _has_text( $row->{hook_id} ) ) {
        return 0;
    }

    return _has_text( $row->{error_class} );
}

sub _assert_role_id_unique {
    my ( $self, $row ) = @_;

    if ( !_role_name_row($row) ) {
        return;
    }
    if ( _role_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('roles_pkey');
    }

    return;
}

sub _role_id_taken {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{role_id} ) ) {
        return 0;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_text( $existing->{role_id}, $row->{role_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _assert_role_unique {
    my ( $self, $row ) = @_;

    if ( !_role_name_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_role_name( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw('roles_name_key');
        }
    }

    return;
}

sub _role_name_row {
    my ($row) = @_;

    if ( !_has_text( $row->{role_id} ) ) {
        return 0;
    }
    if ( _has_text( $row->{permission_id} ) ) {
        return 0;
    }

    return _has_text( $row->{name} );
}

sub _same_role_name {
    my ( $existing, $row ) = @_;

    if ( !_role_name_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{name}, $row->{name} );
}

sub _assert_permission_id_unique {
    my ( $self, $row ) = @_;

    if ( !_permission_catalog_row($row) ) {
        return;
    }
    if ( _permission_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('permissions_pkey');
    }

    return;
}

sub _permission_id_taken {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{permission_id} ) ) {
        return 0;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_text( $existing->{permission_id}, $row->{permission_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _assert_permission_unique {
    my ( $self, $row ) = @_;

    if ( !_permission_catalog_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        $self->_throw_permission_conflict( $existing, $row );
    }

    return;
}

sub _throw_permission_conflict {
    my ( undef, $existing, $row ) = @_;

    if ( _same_permission_name( $existing, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('permissions_name_key');
    }
    if ( _same_permission_action( $existing, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw(
            'permissions_resource_action_key');
    }

    return;
}

sub _permission_catalog_row {
    my ($row) = @_;

    if ( !_has_text( $row->{permission_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{resource_type} ) ) {
        return 0;
    }

    return _has_text( $row->{action} );
}

sub _same_permission_name {
    my ( $existing, $row ) = @_;

    if ( !_permission_catalog_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{name}, $row->{name} );
}

sub _same_permission_action {
    my ( $existing, $row ) = @_;

    if ( !_permission_catalog_row($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{resource_type}, $row->{resource_type} ) ) {
        return 0;
    }

    return _same_text( $existing->{action}, $row->{action} );
}

sub _assert_role_permission_unique {
    my ( $self, $row ) = @_;

    if ( !_role_permission_grant_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_role_permission_grant( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'role_permissions_pkey');
        }
    }

    return;
}

sub _role_permission_grant_row {
    my ($row) = @_;

    if ( !_has_text( $row->{role_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{permission_id} ) ) {
        return 0;
    }

    return !_has_text( $row->{name} );
}

sub _same_role_permission_grant {
    my ( $existing, $row ) = @_;

    if ( !_role_permission_grant_row($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{role_id}, $row->{role_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{permission_id}, $row->{permission_id} );
}

sub _assert_category_id_unique {
    my ( $self, $row ) = @_;

    if ( !_category_slug_row($row) ) {
        return;
    }
    if ( _category_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('categories_pkey');
    }

    return;
}

sub _category_id_taken {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{category_id} ) ) {
        return 0;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_category_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_category_id {
    my ( $existing, $row ) = @_;

    if ( !_category_slug_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{category_id}, $row->{category_id} );
}

sub _assert_category_unique {
    my ( $self, $row ) = @_;

    if ( !_category_slug_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_category_slug( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'categories_space_slug_key');
        }
    }

    return;
}

sub _category_slug_row {
    my ($row) = @_;

    if ( !_has_text( $row->{category_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{space_id} ) ) {
        return 0;
    }

    return _has_text( $row->{slug} );
}

sub _same_category_slug {
    my ( $existing, $row ) = @_;

    if ( !_category_slug_row($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{space_id}, $row->{space_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{slug}, $row->{slug} );
}

sub _assert_legacy_map_id_unique {
    my ( $self, $row ) = @_;

    if ( !_legacy_map_row($row) ) {
        return;
    }
    if ( _legacy_map_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('legacy_id_map_pkey');
    }

    return;
}

sub _legacy_map_id_taken {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{legacy_id_map_id} ) ) {
        return 0;
    }

    for my $existing ( $self->_live_created_rows ) {
        if (
            _same_text(
                $existing->{legacy_id_map_id},
                $row->{legacy_id_map_id}
            )
          )
        {
            return 1;
        }
    }

    return 0;
}

sub _assert_legacy_map_unique {
    my ( $self, $row ) = @_;

    if ( !_legacy_map_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_legacy_source( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'legacy_id_map_source_key');
        }
    }

    return;
}

sub _legacy_map_row {
    my ($row) = @_;

    if ( !_has_text( $row->{legacy_id_map_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{legacy_type} ) ) {
        return 0;
    }

    return _has_text( $row->{legacy_id} );
}

sub _assert_import_job_id_unique {
    my ( $self, $row ) = @_;

    if ( !_import_job_identity_row($row) ) {
        return;
    }
    if ( _import_job_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('import_jobs_pkey');
    }

    return;
}

sub _import_job_identity_row {
    my ($row) = @_;

    if ( !_has_text( $row->{import_job_id} ) ) {
        return 0;
    }
    if ( _has_text( $row->{import_failure_id} ) ) {
        return 0;
    }

    return !_has_text( $row->{legacy_id_map_id} );
}

sub _import_job_id_taken {
    my ( $self, $row ) = @_;

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_import_job_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_import_job_id {
    my ( $existing, $row ) = @_;

    if ( !_import_job_identity_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{import_job_id}, $row->{import_job_id} );
}

sub _assert_import_failure_id_unique {
    my ( $self, $row ) = @_;

    if ( !_import_failure_row($row) ) {
        return;
    }
    if ( _import_failure_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('import_failures_pkey');
    }

    return;
}

sub _import_failure_id_taken {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{import_failure_id} ) ) {
        return 0;
    }

    for my $existing ( $self->_live_created_rows ) {
        if (
            _same_text(
                $existing->{import_failure_id},
                $row->{import_failure_id}
            )
          )
        {
            return 1;
        }
    }

    return 0;
}

sub _assert_import_failure_unique {
    my ( $self, $row ) = @_;

    if ( !_import_failure_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_import_source( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_import_failures_source_unique');
        }
    }

    return;
}

sub _import_failure_row {
    my ($row) = @_;

    if ( !_has_text( $row->{import_failure_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{import_job_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{source_record_type} ) ) {
        return 0;
    }

    return _has_text( $row->{source_record_id} );
}

sub _same_import_source {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{import_job_id}, $row->{import_job_id} ) ) {
        return 0;
    }
    if (
        !_same_text(
            $existing->{source_record_type},
            $row->{source_record_type}
        )
      )
    {
        return 0;
    }

    return _same_text( $existing->{source_record_id},
        $row->{source_record_id} );
}

sub _same_legacy_source {
    my ( $existing, $row ) = @_;

    if ( !_legacy_map_row($existing) ) {
        return 0;
    }
    if ( !_same_text( $existing->{legacy_type}, $row->{legacy_type} ) ) {
        return 0;
    }

    return _same_text( $existing->{legacy_id}, $row->{legacy_id} );
}

sub _assert_space_id_unique {
    my ( $self, $row ) = @_;

    if ( !_space_slug_row($row) ) {
        return;
    }
    if ( _space_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('spaces_pkey');
    }

    return;
}

sub _space_id_taken {
    my ( $self, $row ) = @_;

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_space_id( $existing, $row ) ) {
            return 1;
        }
    }

    return 0;
}

sub _same_space_id {
    my ( $existing, $row ) = @_;

    if ( !_space_slug_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{space_id}, $row->{space_id} );
}

sub _assert_space_unique {
    my ( $self, $row ) = @_;

    if ( !_space_slug_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_space_slug( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw('spaces_slug_key');
        }
    }

    return;
}

sub _space_slug_row {
    my ($row) = @_;

    if ( _has_text( $row->{category_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{space_id} ) ) {
        return 0;
    }

    return _has_text( $row->{slug} );
}

sub _same_space_slug {
    my ( $existing, $row ) = @_;

    if ( !_space_slug_row($existing) ) {
        return 0;
    }

    return _same_text( $existing->{slug}, $row->{slug} );
}

sub _assert_binding_id_unique {
    my ( $self, $row ) = @_;

    if ( !_binding_identity_row($row) ) {
        return;
    }
    if ( _binding_id_taken( $self, $row ) ) {
        GPForum::Infrastructure::UniqueConflict->throw('role_bindings_pkey');
    }

    return;
}

sub _binding_id_taken {
    my ( $self, $row ) = @_;

    if ( !_has_text( $row->{binding_id} ) ) {
        return 0;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_text( $existing->{binding_id}, $row->{binding_id} ) ) {
            return 1;
        }
    }

    return 0;
}

sub _assert_role_binding_unique {
    my ( $self, $row ) = @_;

    if ( !_active_binding_row($row) ) {
        return;
    }

    for my $existing ( $self->_live_created_rows ) {
        if ( _same_active_binding( $existing, $row ) ) {
            GPForum::Infrastructure::UniqueConflict->throw(
                'idx_role_bindings_active_unique');
        }
    }

    return;
}

sub _active_binding_row {
    my ($row) = @_;

    if ( !_binding_identity_row($row) ) {
        return 0;
    }

    return _binding_is_active($row);
}

sub _binding_identity_row {
    my ($row) = @_;

    if ( !_has_text( $row->{binding_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{user_id} ) ) {
        return 0;
    }
    if ( !_has_text( $row->{role_id} ) ) {
        return 0;
    }

    return _has_text( $row->{resource_type} );
}

sub _binding_is_active {
    my ($row) = @_;

    if ( _has_text( $row->{revoked_at} ) ) {
        return 0;
    }

    return 1;
}

sub _same_active_binding {
    my ( $existing, $row ) = @_;

    if ( !_active_binding_row($existing) ) {
        return 0;
    }

    return _same_binding_scope( $existing, $row );
}

sub _same_binding_scope {
    my ( $existing, $row ) = @_;

    if ( !_same_binding_identity( $existing, $row ) ) {
        return 0;
    }

    return _same_binding_resource( $existing, $row );
}

sub _same_binding_identity {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{user_id}, $row->{user_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{role_id}, $row->{role_id} );
}

sub _same_binding_resource {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{resource_type}, $row->{resource_type} ) ) {
        return 0;
    }
    if ( !_same_text( $existing->{resource_id}, $row->{resource_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{space_id}, $row->{space_id} );
}

sub _open_deletion_row {
    my ($row) = @_;

    if ( !_deletion_identity_row($row) ) {
        return 0;
    }

    return _open_deletion_status( $row->{status} );
}

sub _pending_export_row {
    my ($row) = @_;

    if ( !_has_text( $row->{export_request_id} ) ) {
        return 0;
    }

    return _same_text( $row->{status}, 'pending' );
}

sub _same_open_deletion {
    my ( $existing, $row ) = @_;

    if ( !_open_deletion_row($existing) ) {
        return 0;
    }

    return _same_deletion_resource( $existing, $row );
}

sub _same_deletion_resource {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{resource_type}, $row->{resource_type} ) ) {
        return 0;
    }
    if ( !_same_text( $existing->{resource_id}, $row->{resource_id} ) ) {
        return 0;
    }

    return _same_text( $existing->{request_type}, $row->{request_type} );
}

sub _same_pending_export {
    my ( $existing, $row ) = @_;

    if ( !_same_text( $existing->{status}, 'pending' ) ) {
        return 0;
    }

    return _same_export_identity( $existing, $row );
}

sub _same_export_identity {
    my ( $existing, $row ) = @_;

    if (
        !_same_text(
            $existing->{requester_user_id}, $row->{requester_user_id}
        )
      )
    {
        return 0;
    }
    if ( !_same_text( $existing->{subject_user_id}, $row->{subject_user_id} ) )
    {
        return 0;
    }
    if ( !_same_text( $existing->{export_type}, $row->{export_type} ) ) {
        return 0;
    }

    return _same_text( $existing->{format}, $row->{format} );
}

sub _open_deletion_status {
    my ($status) = @_;

    if ( !defined $status ) {
        return 0;
    }
    if ( $status eq 'pending' ) {
        return 1;
    }
    if ( $status eq 'approved' ) {
        return 1;
    }
    if ( $status eq 'held' ) {
        return 1;
    }

    return 0;
}

sub _has_text {
    my ($value) = @_;

    if ( !defined $value ) {
        return 0;
    }

    return length $value ? 1 : 0;
}

sub _open_status {
    my ($status) = @_;

    if ( !defined $status ) {
        return 0;
    }
    if ( $status eq 'open' ) {
        return 1;
    }
    if ( $status eq 'triaged' ) {
        return 1;
    }

    return 0;
}

sub _same_open_report {
    my ( $existing, $row ) = @_;

    if ( !_open_status( $existing->{status} ) ) {
        return 0;
    }

    return _same_report_target( $existing, $row );
}

sub _same_report_target {
    my ( $existing, $row ) = @_;

    if (
        !_same_text( $existing->{reporter_user_id}, $row->{reporter_user_id} ) )
    {
        return 0;
    }
    if ( !_same_text( $existing->{target_type}, $row->{target_type} ) ) {
        return 0;
    }

    return _same_text( $existing->{target_id}, $row->{target_id} );
}

sub _same_text {
    my ( $expected, $actual ) = @_;

    return ( $expected || q{} ) eq ( $actual || q{} ) ? 1 : 0;
}

sub _store_row {
    my ( $self, $row, $object ) = @_;

    for my $key ( _row_keys($row) ) {
        $self->rows->{$key} = $object;
    }

    return;
}

sub _row_keys {
    my ($row) = @_;

    return grep { defined && length } (
        @{$row}{
            qw(
              report_id
              command_id
              event_id
              outbox_id
              category_id
              space_id
              moderation_action_id
              suspension_id
              audit_id
              role_id
              permission_id
              binding_id
              acl_id
              post_id
              thread_id
              import_job_id
              import_failure_id
              legacy_id_map_id
              export_request_id
              plugin_id
              hook_id
              plugin_failure_id
              deletion_request_id
              deletion_action_id
              erasure_job_id
              retention_hold_id
              id
              user_id
            )
        },
        _composite_key($row),
        _legacy_key($row),
    );
}

sub _composite_key {
    my ($row) = @_;

    return join q{:},
      grep { defined } @{$row}{qw(target_type target_id status)};
}

sub _find_key {
    my ($row) = @_;

    return _legacy_key($row) if exists $row->{legacy_type};

    return _composite_key($row);
}

sub _should_filter {
    my ($query) = @_;

    if ( !$query ) {
        return 0;
    }

    return _has_filter_field($query);
}

sub _has_filter_field {
    my ($query) = @_;

    for my $field (
        qw(action_type command_id deletion_request_id event_id export_request_id idempotency_key reporter_user_id)
      )
    {
        if ( exists $query->{$field} ) {
            return 1;
        }
    }

    return 0;
}

sub _matches_query {
    my ( $row, $query ) = @_;

    return 1 if !$query || !%{$query};

    return GPForum::Test::Query::matches( $row, $query, \&_read_column );
}

sub _legacy_key {
    my ($row) = @_;

    return join q{:}, grep { defined } @{$row}{qw(legacy_type legacy_id)};
}

sub _read_column {
    my ( $row, $column ) = @_;

    return $row->get_column($column);
}

1;
