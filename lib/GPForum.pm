package GPForum;

use strict;
use warnings;

use Mojo::Base 'Mojolicious';

use GPForum::Config;
use GPForum::Log;
use GPForum::Runtime;
use GPForum::Schema;
use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Forum::CategoryReader;
use GPForum::Service::Forum::PostComposer;
use GPForum::Service::Forum::PostPosition;
use GPForum::Service::Forum::PostReader;
use GPForum::Service::Forum::PostStore;
use GPForum::Service::Forum::ReadState;
use GPForum::Service::Forum::ThreadComposer;
use GPForum::Service::Forum::ThreadDetailReader;
use GPForum::Service::Forum::ThreadReader;
use GPForum::Service::Forum::ThreadStore;
use GPForum::Service::Identity::Registration;
use GPForum::Service::Identity::Store;
use GPForum::Service::Operations::LocalCache;
use GPForum::Service::Operations::MetricsSnapshot;
use GPForum::Service::Operations::RateLimiter;
use GPForum::Service::Operations::Readiness;
use GPForum::Service::Password;
use GPForum::Service::Realtime::Hub;
use GPForum::Service::Search::Searcher;
use GPForum::Service::SessionToken;

our $VERSION = '0.001';

sub startup {
    my ($self) = @_;

    my $config    = GPForum::Config->from_environment;
    my $runtime   = GPForum::Runtime->from_config($config);
    my $root_path = q{/};

    $self->secrets( [ $config->session_secret ] );
    $self->mode( $config->environment );

    $self->helper( gp_config  => sub { return $config; } );
    $self->helper( gp_runtime => sub { return $runtime; } );
    my $schema;
    $self->helper(
        gp_schema => sub {
            $schema ||= GPForum::Schema->connect_from_config($config);
            return $schema;
        }
    );
    $self->helper( gp_clock => sub { return GPForum::Service::Clock->new; } );
    $self->helper( gp_id    => sub { return GPForum::Service::Id->new; } );
    $self->helper(
        gp_password => sub { return GPForum::Service::Password->new; } );
    $self->helper(
        gp_session_token => sub { return GPForum::Service::SessionToken->new; }
    );
    my $local_cache;
    $self->helper(
        gp_local_cache => sub {
            $local_cache ||= GPForum::Service::Operations::LocalCache->new(
                max_entries => $config->local_cache_max_entries,
                namespace   => 'gpforum',
            );
            return $local_cache;
        }
    );
    $self->helper( gp_registration =>
          sub { return GPForum::Service::Identity::Registration->new; } );
    $self->helper(
        gp_identity_store => sub {
            return GPForum::Service::Identity::Store->new(
                schema => shift->gp_schema );
        }
    );
    my $realtime_hub;
    $self->helper(
        gp_realtime_hub => sub {
            $realtime_hub ||= GPForum::Service::Realtime::Hub->new;
            return $realtime_hub;
        }
    );
    my $rate_limiter;
    $self->helper(
        gp_rate_limiter => sub {
            $rate_limiter ||= GPForum::Service::Operations::RateLimiter->new;
            return $rate_limiter;
        }
    );
    $self->helper(
        gp_metrics_snapshot => sub {
            my ($controller) = @_;

            return GPForum::Service::Operations::MetricsSnapshot->new(
                runtime      => $runtime,
                schema       => $controller->gp_schema,
                realtime_hub => $controller->gp_realtime_hub,
                rate_limiter => $controller->gp_rate_limiter,
                local_caches => [ $controller->gp_local_cache ],
            );
        }
    );
    $self->helper(
        gp_readiness => sub {
            my ($controller) = @_;

            return GPForum::Service::Operations::Readiness->new(
                environment => $config->environment,
                runtime     => $runtime,
                schema      => $controller->gp_schema,
            );
        }
    );
    $self->helper(
        gp_category_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::CategoryReader->new(
                cache             => $controller->gp_local_cache,
                cache_ttl_seconds => $config->category_cache_ttl_seconds,
                schema            => $controller->gp_schema,
            );
        }
    );
    $self->helper(
        gp_thread_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadReader->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_post_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostReader->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_thread_detail_reader => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadDetailReader->new(
                schema      => $controller->gp_schema,
                post_reader => $controller->gp_post_reader,
            );
        }
    );
    $self->helper(
        gp_thread_composer => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadComposer->new(
                id_service => $controller->gp_id );
        }
    );
    $self->helper(
        gp_thread_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ThreadStore->new(
                schema     => $controller->gp_schema,
                id_service => $controller->gp_id,
            );
        }
    );
    $self->helper(
        gp_post_composer => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostComposer->new(
                id_service => $controller->gp_id );
        }
    );
    $self->helper(
        gp_post_store => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostStore->new(
                schema     => $controller->gp_schema,
                id_service => $controller->gp_id,
            );
        }
    );
    $self->helper(
        gp_post_position => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::PostPosition->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_thread_read_state => sub {
            my ($controller) = @_;

            return GPForum::Service::Forum::ReadState->new(
                schema => $controller->gp_schema );
        }
    );
    $self->helper(
        gp_search_service => sub {
            my ($controller) = @_;

            return GPForum::Service::Search::Searcher->new(
                schema => $controller->gp_schema );
        }
    );

    GPForum::Log->configure( $self, $config );

    my $routes = $self->routes;

    $routes->get($root_path)->to('Home#show')->name('home');
    $routes->get('/health')->to('Health#summary')->name('health');
    $routes->get('/health/live')->to('Health#live')->name('health_live');
    $routes->get('/health/ready')->to('Health#ready')->name('health_ready');
    $routes->get('/metrics')->to('Operations#metrics')->name('metrics');
    $routes->get('/categories')->to('Forum#categories')->name('categories');
    $routes->get('/c/:category_id')->to('Forum#category')->name('category');
    $routes->get('/t/:thread_id')->to('Forum#thread')->name('thread');
    $routes->get('/new-thread')
      ->to('Forum#new_thread_form')
      ->name('new_thread');
    $routes->post('/threads')->to('Forum#create_thread')->name('thread_create');
    $routes->post('/t/:thread_id/replies')
      ->to('Forum#create_reply')
      ->name('reply_create');
    $routes->post('/t/:thread_id/read')
      ->to('Forum#mark_thread_read')
      ->name('thread_mark_read');
    $routes->get('/search')->to('Forum#search')->name('forum_search');
    $routes->get('/register')->to('Identity#register_form')->name('register');
    $routes->post('/register')
      ->to('Identity#register')
      ->name('register_submit');
    $routes->get('/login')->to('Identity#login_form')->name('login');
    $routes->post('/login')->to('Identity#login')->name('login_submit');
    $routes->post('/logout')->to('Identity#logout')->name('logout');
    $routes->get('/u/:username')->to('Identity#profile')->name('profile');
    $routes->websocket('/realtime')->to('Realtime#stream')->name('realtime');

    return;
}

1;

__END__

=head1 NAME

GPForum - Mojolicious application root.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $app = GPForum->new;

=head1 DESCRIPTION

Bootstraps the GPForum web application, helpers, logging, runtime profile, and
initial routes for milestone zero.

=head1 SUBROUTINES/METHODS

=head2 startup

Configures application dependencies and routes.

=head1 DIAGNOSTICS

Startup delegates configuration validation to L<GPForum::Config>.

=head1 CONFIGURATION AND ENVIRONMENT

Reads runtime configuration through L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<Mojolicious> plus GPForum configuration, logging, runtime, clock, and ID
services.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Milestone zero exposes only home and health endpoints.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
