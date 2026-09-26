# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Plugin::HookDispatcher;

use strict;
use warnings;

use Mojo::Base -base, -signatures;
use Try::Tiny;

our $VERSION = '0.001';

has failure_recorder => undef;
has handlers         => sub { return {}; };
has schema           => undef;

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
    my $error = try {
        $result = $handler->( $payload, $hook );
        return;
    }
    catch {
        return $_;
    };
    if ($error) {
        return $self->_record_failure(
            $hook,
            {
                error_class   => 'handler_error',
                error_message => "$error",
                payload       => $payload,
            }
        );
    }

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
