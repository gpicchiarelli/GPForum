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
use GPForum::Service::Identity::Registration;
use GPForum::Service::Identity::Store;
use GPForum::Service::Password;
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
    $self->helper( gp_registration =>
          sub { return GPForum::Service::Identity::Registration->new; } );
    $self->helper(
        gp_identity_store => sub {
            return GPForum::Service::Identity::Store->new(
                schema => shift->gp_schema );
        }
    );

    GPForum::Log->configure( $self, $config );

    my $routes = $self->routes;

    $routes->get($root_path)->to('Home#show')->name('home');
    $routes->get('/health')->to('Health#summary')->name('health');
    $routes->get('/health/live')->to('Health#live')->name('health_live');
    $routes->get('/health/ready')->to('Health#ready')->name('health_ready');
    $routes->get('/register')->to('Identity#register_form')->name('register');
    $routes->post('/register')
      ->to('Identity#register')
      ->name('register_submit');
    $routes->get('/login')->to('Identity#login_form')->name('login');
    $routes->post('/login')->to('Identity#login')->name('login_submit');
    $routes->post('/logout')->to('Identity#logout')->name('logout');
    $routes->get('/u/:username')->to('Identity#profile')->name('profile');

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
