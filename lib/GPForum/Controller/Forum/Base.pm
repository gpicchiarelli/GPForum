# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Controller::Forum::Base;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base 'Mojolicious::Controller', -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Web::Access;
use GPForum::Web::ForumAccess;
use GPForum::Web::Guard;
use GPForum::Web::Responder;
use GPForum::Web::RequestPreference;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_CREATED      => 201;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $HTTP_TOO_MANY     => 429;

sub forum_access {
    return GPForum::Web::ForumAccess->new;
}

sub visible_thread ($self) {
    my $thread =
      $self->gp_thread_detail_reader->find_thread( $self->param('thread_id'),
        $self->gp_forum_viewer );

    if ( !$thread ) {
        $self->_not_found('thread not found');
        my $undefined;
        return $undefined;
    }

    return $thread;
}

sub attachments_for_posts ( $self, $posts ) {
    if ( !@{$posts} ) {
        return {};
    }

    my $by_post = eval {
        return $self->gp_attachment_store->attachments_for_posts(
            [ map { $self->_column( $_, 'post_id' ) } @{$posts} ],
            {
                viewer         => $self->gp_forum_viewer,
                viewer_user_id => $self->_current_user_id,
            },
        );
    };
    if ($EVAL_ERROR) {
        $self->app->log->warn("attachment listing degraded: $EVAL_ERROR");
        return {};
    }

    return $by_post || {};
}

sub create_report ( $self, $input ) {
    my $prepared = $self->_report_input($input);
    if ( !$prepared->{ok} ) {
        return $prepared;
    }

    return $self->_commanded_report( $prepared->{report} );
}

sub _commanded_report ( $self, $report ) {
    return $self->_mapped_report(
        $self->gp_community_workflow->create_report(
            {
                command_id => $self->command_id_param,
                %{$report},
            }
        )
    );
}

sub _mapped_report ( $self, $result ) {
    if ( $result->{ok} ) {
        return { ok => 1, report => $result->{stored} };
    }

    return $self->_failed_report($result);
}

sub _failed_report ( $self, $result ) {
    if ( $self->forum_access->is_unavailable($result) ) {
        return { ok => 0, system_error => 1 };
    }

    return {
        error  => $result->{error},
        errors => $result->{errors},
        ok     => 0,
        status => $result->{status},
    };
}

sub _report_input ( $self, $input ) {
    my $reason  = $self->_trim( $self->param('reason') );
    my $details = $self->_trim( $self->param('details') );
    my $errors  = $self->forum_access->report_field_errors( $reason, $details );
    if ( %{$errors} ) {
        return { ok => 0, errors => $errors };
    }

    return {
        ok     => 1,
        report => {
            reporter_user_id => $input->{reporter_user_id},
            target_type      => $input->{target_type},
            target_id        => $input->{target_id},
            reason           => $reason,
            details          => $details,
        },
    };
}

sub report_response ( $self, $result, $thread_id, $post_id ) {
    if ( !$result->{ok} ) {
        return $self->_report_error_response($result);
    }
    if ( $self->_wants_json ) {
        return $self->_report_json_response($result);
    }

    return $self->_report_redirect( $thread_id, $post_id );
}

sub profilereport_response ( $self, $result, $username ) {
    if ( !$result->{ok} ) {
        return $self->_report_error_response($result);
    }
    if ( $self->_wants_json ) {
        return $self->_report_json_response($result);
    }

    return $self->_html_success(
        $self->forum_access->reported_status,
        $self->url_for( 'profile', username => $username ),
    );
}

sub _report_error_response ( $self, $result ) {
    if ( $self->forum_access->is_unavailable($result) ) {
        return $self->_service_unavailable;
    }

    return $self->_report_client_error($result);
}

sub _report_client_error ( $self, $result ) {
    if ( ( $result->{status} || q{} ) eq 'conflict' ) {
        return $self->_conflict( $result->{error} );
    }

    return $self->_bad_request( $result->{errors} );
}

sub _report_json_response ( $self, $result ) {
    return $self->render(
        json =>
          $self->gp_forum_view_model->report_response( $result->{report}, ),
        status => $HTTP_OK,
    );
}

sub _report_redirect ( $self, $thread_id, $post_id ) {
    my $url = $self->url_for( 'thread', thread_id => $thread_id );
    if ($post_id) {
        $url->fragment( 'post-' . $post_id );
    }

    return $self->_html_success( $self->forum_access->reported_status, $url );
}

sub created_thread_response ( $self, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json =>
              $self->gp_forum_view_model->created_thread_response($stored),
            status => $HTTP_CREATED,
        );
    }

    return $self->_html_success(
        $self->forum_access->thread_created_status,
        $self->url_for(
            'thread',
            thread_id => $self->_column( $stored->{thread}, 'thread_id' ),
        ),
    );
}

sub updated_thread_response ( $self, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json =>
              $self->gp_forum_view_model->updated_thread_response($stored),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success(
        $self->forum_access->thread_updated_status,
        $self->url_for(
            'thread',
            thread_id => $self->_column( $stored->{thread}, 'thread_id' ),
        ),
    );
}

sub moved_thread_response ( $self, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_forum_view_model->moved_thread_response($stored),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success(
        $self->forum_access->thread_moved_status,
        $self->url_for(
            'thread',
            thread_id => $self->_column( $stored->{thread}, 'thread_id' ),
        ),
    );
}

sub deleted_thread_response ( $self, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json =>
              $self->gp_forum_view_model->deleted_thread_response($stored),
            status => $HTTP_OK,
        );
    }

    return $self->_redirect_after_thread_delete($stored);
}

sub restored_thread_response ( $self, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json =>
              $self->gp_forum_view_model->restored_thread_response($stored),
            status => $HTTP_OK,
        );
    }

    my $thread_id = $self->_column( $stored->{thread}, 'thread_id' );

    return $self->_html_success(
        $self->forum_access->thread_restored_status,
        $self->url_for( 'thread', thread_id => $thread_id ),
    );
}

sub _redirect_after_thread_delete ( $self, $stored ) {
    my $status      = $self->forum_access->thread_deleted_status;
    my $category_id = $self->_column( $stored->{thread}, 'category_id' );
    if ($category_id) {
        return $self->_html_success( $status,
            $self->url_for( 'category', category_id => $category_id ),
        );
    }

    return $self->_html_success( $status, $self->url_for('categories') );
}

sub created_post_response ( $self, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_forum_view_model->created_post_response($stored),
            status => $HTTP_CREATED,
        );
    }

    my $thread_id = $self->param('thread_id');
    my $post_id   = $self->_column( $stored->{post}, 'post_id' );

    return $self->_html_success(
        $self->forum_access->post_created_status,
        $self->url_for( 'thread', thread_id => $thread_id )
          ->fragment( 'post-' . $post_id ),
    );
}

sub updated_post_response ( $self, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_forum_view_model->updated_post_response($stored),
            status => $HTTP_OK,
        );
    }

    my $thread_id = $self->_column( $stored->{post}, 'thread_id' );
    my $post_id   = $self->_column( $stored->{post}, 'post_id' );

    return $self->_html_success(
        $self->forum_access->post_updated_status,
        $self->url_for( 'thread', thread_id => $thread_id )
          ->fragment( 'post-' . $post_id ),
    );
}

sub deleted_post_response ( $self, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_forum_view_model->deleted_post_response($stored),
            status => $HTTP_OK,
        );
    }

    my $thread_id = $self->_column( $stored->{post}, 'thread_id' );

    return $self->_html_success(
        $self->forum_access->post_deleted_status,
        $self->url_for( 'thread', thread_id => $thread_id ),
    );
}

sub restored_post_response ( $self, $stored ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_forum_view_model->restored_post_response($stored),
            status => $HTTP_OK,
        );
    }

    my $thread_id = $self->_column( $stored->{post}, 'thread_id' );
    my $post_id   = $self->_column( $stored->{post}, 'post_id' );

    return $self->_html_success(
        $self->forum_access->post_restored_status,
        $self->url_for( 'thread', thread_id => $thread_id )
          ->fragment( 'post-' . $post_id ),
    );
}

sub read_marker_response ( $self, $marked ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json   => $self->gp_forum_view_model->read_marker_response($marked),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success(
        $self->forum_access->read_marked_status,
        $self->url_for(
            'thread', thread_id => $marked->{read_state}{thread_id},
        ),
    );
}

sub bookmark_action_response ( $self, $status, $bookmark ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_community_view_model->bookmark_response(
                $status, $bookmark,
            ),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status,
        $self->url_for( 'thread', thread_id => $self->param('thread_id') ),
    );
}

sub subscription_action_response ( $self, $status, $subscription ) {
    if ( $self->_wants_json ) {
        return $self->render(
            json => $self->gp_community_view_model->subscription_response(
                $status, $subscription
            ),
            status => $HTTP_OK,
        );
    }

    return $self->_html_success( $status,
        $self->url_for( 'thread', thread_id => $self->param('thread_id') ),
    );
}

sub render_payload ( $, $input ) {
    return GPForum::Web::Responder->new->payload($input);
}

# Cache options for a public page, or none: a page past the first (with a
# cursor) is not cached, since any string is a cursor and each would mint an
# entry.
sub public_cache_options ( $self, $name, $tags ) {
    my $undefined;
    return $undefined if length( $self->param('after') // q{} );

    my $path = $self->req->url->path;
    return $self->forum_access->public_cache_options(
        {
            limit  => $self->list_page_limit,
            locale => $self->ui_locale,
            name   => $name,
            path   => $path->to_string,
            tags   => $tags,
            theme  => $self->ui_theme,
        }
    );
}

# Answers from the public cache before the page's queries run, when the
# visitor is anonymous, wants HTML and the page is cached: a hit used to
# spare only the template, after every query had run. True when answered.
# On a miss the options come back marked, so the page must hand these same
# options to render_payload: its render then stores without a second lookup.
sub served_from_public_cache ( $self, $options ) {
    return 0 if !$options;
    return 0 if GPForum::Web::RequestPreference->wants_json($self);

    return $self->gp_public_http_cache->serve_cached( $self, $options );
}

sub _html_success ( $self, $status, $location ) {
    $self->_set_success_flash( $self->forum_access->write_flash_key($status) );

    return $self->redirect_to($location);
}

sub _set_success_flash ( $self, $flash_key ) {
    if ( !$flash_key ) {
        return;
    }

    $self->flash( success => $self->t($flash_key) );

    return;
}

sub _wants_json ($self) {
    return GPForum::Web::Access->new->wants_json($self);
}

sub _thread_form_bad_request ( $self, $prepared ) {
    if ( $self->_wants_json ) {
        return $self->_bad_request( $prepared->{errors} );
    }

    return $self->_thread_form_invalid_html($prepared);
}

sub _thread_form_invalid_html ( $self, $prepared ) {
    my $categories = $self->gp_category_reader->list_categories(
        { viewer => $self->gp_forum_viewer } );
    my $values     = $prepared->{values} || {};
    my $form_state = $self->_thread_form_state($values);

    return $self->render(
        template => 'forum/new_thread',
        status   => $HTTP_BAD_REQUEST,
        %{
            $self->gp_forum_view_model->new_thread_form(
                categories           => $categories,
                command_id           => $form_state->{command_id},
                csrf_token           => $self->csrf_token,
                errors               => $prepared->{errors} || {},
                selected_category_id => $form_state->{selected_category_id},
                values               => $values,
            )
        },
    );
}

sub _thread_form_state ( $self, $values ) {
    return {
        command_id           => $self->_thread_form_command_id($values),
        selected_category_id =>
          $self->_thread_form_selected_category_id($values),
    };
}

sub _thread_form_command_id ( $self, $values ) {
    if ( defined $values->{command_id} && length $values->{command_id} ) {
        return $values->{command_id};
    }

    return $self->_new_command_id;
}

sub _thread_form_selected_category_id ( $self, $values ) {
    if ( defined $values->{category_id} && length $values->{category_id} ) {
        return $values->{category_id};
    }

    return $self->_trim( $self->param('category_id') );
}

sub thread_write_failure ( $self, $result ) {
    return $self->_write_failure(
        $result,
        {
            conflict => sub {
                return $self->_conflict( $result->{error} );
            },
            invalid => sub {
                return $self->_thread_form_bad_request( $result->{prepared} );
            },
            not_found => sub {
                return $self->_not_found( $result->{error} );
            },
        }
    );
}

sub reply_write_failure ( $self, $result ) {
    return $self->_write_failure(
        $result,
        {
            conflict => sub {
                return $self->_conflict( $result->{error} );
            },
            forbidden => sub {
                return $self->_forbidden( $result->{error} );
            },
            invalid => sub {
                return $self->_bad_request( $result->{prepared}{errors} );
            },
            not_found => sub {
                return $self->_not_found( $result->{error} );
            },
        }
    );
}

sub _write_failure ( $self, $result, $handlers ) {
    if ( $self->forum_access->is_unavailable($result) ) {
        return $self->_service_unavailable;
    }

    my $status  = $result->{status} || q{};
    my $handler = $handlers->{$status};
    if ($handler) {
        return $handler->();
    }

    return $self->_system_failure;
}

sub _allowed ( $self, $user_id, $action ) {
    my $decision = $self->gp_rate_limiter->check(
        $self->forum_access->write_rate_input(
            {
                action   => $action,
                actor_id => $user_id,
            }
        )
    );

    return $decision->{ok};
}

sub read_allowed ( $self, $action ) {
    my $actor_id = $self->_current_user_id || $self->_request_address;
    my $decision = $self->gp_rate_limiter->check(
        $self->forum_access->read_rate_input(
            {
                action   => $action,
                actor_id => $actor_id,
            }
        )
    );

    return $decision->{ok};
}

sub write_user_id ( $self, $action ) {
    my $undefined;

    if ( $self->_reject_bad_csrf ) {
        return $undefined;
    }

    my $user_id = $self->_current_user_id;
    if ( $self->_reject_unauthenticated($user_id) ) {
        return $undefined;
    }
    if ( $self->_reject_rate_limited( $user_id, $action ) ) {
        return $undefined;
    }
    if ( $self->_reject_suspended( $user_id, $action ) ) {
        return $undefined;
    }

    return $user_id;
}

sub _reject_bad_csrf ($self) {
    if ( GPForum::Web::Access->new->csrf_invalid($self) ) {
        $self->_csrf_failure;
        return 1;
    }

    return;
}

sub _reject_unauthenticated ( $self, $user_id ) {
    if ( !$user_id ) {
        $self->_unauthorized;
        return 1;
    }

    return;
}

sub _reject_rate_limited ( $self, $user_id, $action ) {
    if ( !$self->_allowed( $user_id, $action ) ) {
        $self->_rate_limited;
        return 1;
    }

    return;
}

sub _reject_suspended ( $self, $user_id, $action ) {
    if ( !$self->forum_access->requires_participation($action) ) {
        return;
    }
    if ( $self->_can_participate($user_id) ) {
        return;
    }

    $self->_record_security_event(
        'suspended_user_block',
        {
            action => $action,
            status => $HTTP_FORBIDDEN,
        }
    );
    $self->_forbidden('user is suspended');
    return 1;
}

sub _can_participate ( $self, $user_id ) {
    my $decision = $self->gp_suspension_store->can_participate($user_id);
    return $decision->{ok};
}

sub search_filters ($self) {
    my %filters;
    for my $field ( $self->forum_access->search_filter_fields ) {
        my $value = $self->_trim( $self->param($field) );
        if ( length $value ) {
            $filters{$field} = $value;
        }
    }

    return \%filters;
}

sub _column ( $, $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub _current_user_id ($self) {
    return GPForum::Web::Access->new->user_id($self);
}

sub _new_command_id ($self) {
    return $self->gp_id->uuid;
}

sub command_id_param ($self) {
    my $command_id = $self->_trim( $self->param('command_id') );
    if ( length $command_id ) {
        return $command_id;
    }

    return $self->_trim( $self->param('idempotency_key') );
}

sub _request_address ($self) {
    return $self->tx->remote_address || 'anonymous';
}

sub _trim ( $, $value ) {
    if ( !defined $value ) {
        $value = q{};
    }
    $value =~ s/\A \s+//msx;
    $value =~ s/\s+ \z//msx;

    return $value;
}

sub is_non_negative_integer ( $self, $value ) {
    return $self->forum_access->is_non_negative_integer($value);
}

sub bounded_limit ( $self, $value, $default, $maximum ) {
    return $self->forum_access->bounded_limit(
        {
            default => $default,
            maximum => $maximum,
            value   => $value,
        }
    );
}

sub list_page_limit ($self) {
    return $self->forum_access->list_page_limit( $self->param('limit') );
}

sub _bad_request ( $self, $errors ) {
    return GPForum::Web::Guard->new->bad_request(
        $self,
        {
            error  => 'The submitted forum request was invalid.',
            errors => $errors,
            title  => 'Invalid request',
        }
    );
}

sub _csrf_failure ($self) {
    $self->_record_security_event(
        'csrf_failure',
        {
            status => $HTTP_FORBIDDEN,
        }
    );

    return GPForum::Web::Guard->new->csrf_failure($self);
}

sub _unauthorized ($self) {
    $self->_record_security_event(
        'auth_denial',
        {
            status => $HTTP_UNAUTHORIZED,
        }
    );

    return GPForum::Web::Guard->new->unauthorized($self);
}

sub _forbidden ( $self, $error ) {
    $self->_record_security_event(
        'auth_denial',
        {
            reason => 'forbidden',
            status => $HTTP_FORBIDDEN,
        }
    );

    return GPForum::Web::Guard->new->forbidden(
        $self,
        {
            error => $error,
        }
    );
}

sub _not_found ( $self, $error ) {
    return GPForum::Web::Guard->new->not_found( $self, $error );
}

sub _rate_limited ($self) {
    $self->_record_security_event(
        'rate_limit_hit',
        {
            status => $HTTP_TOO_MANY,
        }
    );

    return GPForum::Web::Guard->new->rate_limited($self);
}

sub _conflict ( $self, $error ) {
    return GPForum::Web::Guard->new->conflict(
        $self,
        {
            error => $error || 'idempotency conflict',
            title => 'Conflict',
        }
    );
}

sub _system_failure ($self) {
    return GPForum::Web::Guard->new->system_failure($self);
}

sub _service_unavailable ($self) {
    return GPForum::Web::Guard->new->service_unavailable($self);
}

sub _record_security_event ( $self, $event_type, $metadata ) {
    return $self->gp_security_telemetry->record(
        $event_type,
        {
            %{$metadata}, route => $self->_current_route_name,
        }
    );
}

sub _current_route_name ($self) {
    my $route = eval { return $self->current_route; };
    if ($route) {
        return $route;
    }

    return 'unknown';
}

1;

__END__

=head1 NAME

GPForum::Controller::Forum::Base - Shared forum HTTP helpers.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use Mojo::Base 'GPForum::Controller::Forum::Base';

=head1 DESCRIPTION

Owns CSRF, auth, rate-limit checks, Guard errors, and response helpers used
by forum read, write, community, and search controllers. Rate-limit hashes,
report field errors, and integer limits live on
L<GPForum::Web::ForumAccess>.

=head1 SUBROUTINES/METHODS

=head2 write_user_id

Returns the authenticated actor after CSRF, rate-limit, and suspension
checks, or renders the matching HTTP error.

=head1 DIAGNOSTICS

HTTP errors are rendered through L<GPForum::Web::Guard>.

=head1 CONFIGURATION AND ENVIRONMENT

Uses forum helpers registered during application startup.

=head1 DEPENDENCIES

Uses L<Mojolicious::Controller>, L<GPForum::Web::Access>,
L<GPForum::Web::ForumAccess>, L<GPForum::Web::Guard>, and
L<GPForum::Web::Responder>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Helpers are HTTP-oriented and must not talk to DBIx::Class resultsets.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
