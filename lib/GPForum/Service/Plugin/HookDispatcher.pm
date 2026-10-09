# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Plugin::HookDispatcher;

use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

our $VERSION = '0.001';

__PACKAGE__->requires(qw(failure_recorder schema));
has handlers => sub { return {}; };

sub dispatch ( $self, $hook_name, $payload ) {
    my @results;
    my $search = $self->schema->resultset('PluginHook')->search_rs(
        {
            hook_name => $hook_name,
            enabled   => 1,
        },
        {
            order_by => [ { -asc => 'execution_order' } ],
        }
    );

    for my $hook ( _rows($search) ) {
        push @results, $self->_dispatch_hook( $hook, $payload );
    }

    return { hook_name => $hook_name, results => \@results };
}

sub _dispatch_hook ( $self, $hook, $payload ) {
    my $callback = $hook->get_column('callback_name');
    my $handler  = $self->handlers->{$callback};

    if ( !$handler ) {
        return $self->_record_failure(
            $hook,
            {
                error_class   => 'missing_handler',
                error_message => 'plugin callback is not registered',
                payload       => $payload,
            }
        );
    }

    my $result;
    try {
        $result = $handler->( $payload, $hook );
    }
    catch ($error) {
        return $self->_record_failure(
            $hook,
            {
                error_class   => 'handler_error',
                error_message => "$error",
                payload       => $payload,
            }
        );
    };

    return {
        ok            => 1,
        plugin_id     => $hook->get_column('plugin_id'),
        hook_name     => $hook->get_column('hook_name'),
        callback_name => $callback,
        result        => $result,
    };
}

sub _record_failure ( $self, $hook, $failure ) {
    my $recorded = $self->failure_recorder->record_failure(
        {
            plugin_id     => $hook->get_column('plugin_id'),
            hook_name     => $hook->get_column('hook_name'),
            error_class   => $failure->{error_class},
            error_message => $failure->{error_message},
            context       => { payload => $failure->{payload} },
        }
    );

    return { ok => 0, failure => $recorded };
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Plugin::HookDispatcher - Run the enabled plugin callbacks registered for a hook.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $dispatcher = GPForum::Service::Plugin::HookDispatcher->new(
        failure_recorder => GPForum::Service::Plugin::FailureRecorder->new(
            schema => $schema,
        ),
        handlers => {
            'example.on_post' => sub {
                my ( $payload, $hook ) = @_;
                return 'seen';
            },
        },
        schema => $schema,
    );
    my $outcome = $dispatcher->dispatch( 'post.created', { post_id => $id } );
    # $outcome->{results} holds one entry per enabled hook, in order

=head1 DESCRIPTION

Looks up the enabled C<plugin_hooks> rows for a hook name, in
C<execution_order>, and calls the handler registered under each row's
C<callback_name> with the payload. One plugin cannot stop the others: a
callback with no registered handler, or a handler that dies, is recorded
as a plugin failure through the failure recorder and dispatch moves on to
the next hook. Only the hook row's C<enabled> flag is consulted, not the
status of the plugin it belongs to.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<schema> is the DBIx::Class schema;
C<failure_recorder> is an object with C<record_failure>, such as
L<GPForum::Service::Plugin::FailureRecorder>; C<handlers> maps callback
names to code references and defaults to an empty hash.

=head2 dispatch

Takes a hook name and a payload. Calls each enabled hook's handler as
C<< $handler->( $payload, $hook_row ) >> and returns
C<< { hook_name => $hook_name, results => \@results } >>. Each result is
either C<< { ok => 1, plugin_id, hook_name, callback_name, result } >>,
with the handler's return value in C<result>, or
C<< { ok => 0, failure => $recorded } >>, where C<$recorded> is what the
failure recorder returned for a C<missing_handler> or C<handler_error>
failure (the error text goes into the failure's C<error_message>, the
payload into its C<context>). With no enabled hooks, C<results> is empty.

=head1 DIAGNOSTICS

Handler errors are caught and recorded, never rethrown. Database errors
from the hook query and errors from the failure recorder propagate.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::Service::Plugin::FailureRecorder>.

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
