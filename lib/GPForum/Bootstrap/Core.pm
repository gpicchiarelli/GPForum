# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Bootstrap::Core;

use v5.40;

use Compress::Raw::Zlib qw(WANT_GZIP Z_OK);
use Const::Fast;

use GPForum::Service::Attachment::Validator;
use GPForum::Service::Clock;
use GPForum::Infrastructure::Id;
use GPForum::Service::Forum::Readability;
use GPForum::Service::Realtime::ChannelAuthorizer;
use GPForum::Service::Realtime::Hub;
use GPForum::Service::Realtime::ListenerSupervisor;
use GPForum::Service::Realtime::PgListener;
use GPForum::Service::Realtime::PgNotifier;
use GPForum::Service::Realtime::SubscriptionPolicy;
use GPForum::Web::Warmup;

our $VERSION = '0.001';

# What a request may carry beyond the largest attachment: the multipart form
# around it. The shipped nginx configurations allow the same 26 MiB.
const my $FORM_ALLOWANCE => 1_024 * 1_024;

# zlib's level for a page: on the signed-in thread page (79 KB) level 3
# takes 0.67 ms and writes 9.0 KB where the default level 6 takes 1.28 ms
# for 8.1 KB, and the IO::Compress layers Mojolicious goes through add 0.3
# ms more. The 900 bytes cost a reader on a 20 Mbit link under half a
# millisecond; the 0.9 ms of CPU was 4% of the page.
const my $GZIP_LEVEL => 3;

# Compiled templates the renderer keeps. Mojolicious keeps 100 and drops
# the oldest past that; the application has 83 template files, and a
# process that outgrew the hundred would compile templates again on every
# page, a few milliseconds each, without saying so.
const my $TEMPLATE_CACHE_KEYS => 512;

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};
    my $config      = $input{config};

    $application->secrets( $config->signing_secrets );
    $application->mode( $config->environment );

    # Mojolicious cuts a request off at 16 MiB unless told otherwise, so an
    # attachment between that and the validator's 25 MiB never reached the
    # validator: the upload failed without saying why.
    $application->max_request_size(
        GPForum::Service::Attachment::Validator->max_bytes + $FORM_ALLOWANCE );
    _configure_static_assets($application);
    _configure_compression($application);
    $application->renderer->cache->max_keys($TEMPLATE_CACHE_KEYS);
    _configure_warmup( $application, $config );

    $application->helper(
        gp_clock => sub { return GPForum::Service::Clock->new; } );
    $application->helper(
        gp_id => sub { return GPForum::Infrastructure::Id->new; } );

    my $realtime_hub;
    $application->helper(
        gp_realtime_hub => sub {
            my ($controller) = @_;

            return $realtime_hub if $realtime_hub;

            my $readability = GPForum::Service::Forum::Readability->new(
                schema => $controller->gp_schema );
            $realtime_hub = GPForum::Service::Realtime::Hub->new(
                authorizer =>
                  GPForum::Service::Realtime::ChannelAuthorizer->new(
                    permission_engine =>
                      GPForum::Service::Realtime::SubscriptionPolicy->new(
                        permission_gate  => $controller->gp_permission_gate,
                        readability      => $readability,
                        schema           => $controller->gp_schema,
                        suspension_store => $controller->gp_suspension_store,
                      ),
                  ),
                badge_counter => _badge_counter($controller),
                readability   => $readability,
            );
            return $realtime_hub;
        }
    );

    my $realtime_pg_notifier;
    $application->helper(
        gp_realtime_pg_notifier => sub {
            my ($controller) = @_;

            $realtime_pg_notifier ||=
              GPForum::Service::Realtime::PgNotifier->new(
                schema => $controller->gp_schema, );
            return $realtime_pg_notifier;
        }
    );

    my $realtime_pg_listener;
    $application->helper(
        gp_realtime_pg_listener => sub {
            my ($controller) = @_;

            $realtime_pg_listener ||=
              GPForum::Service::Realtime::PgListener->new(
                hub           => $controller->gp_realtime_hub,
                notifications => $controller->gp_pg_notifications,
                schema        => $controller->gp_schema,
              );
            return $realtime_pg_listener;
        }
    );

    my $realtime_listener_supervisor;
    $application->helper(
        gp_realtime_listener_supervisor => sub {
            my ($controller) = @_;

            $realtime_listener_supervisor ||=
              GPForum::Service::Realtime::ListenerSupervisor->new(
                enabled => $config->realtime_listener_enabled,
                heartbeat_interval_seconds =>
                  $config->realtime_listener_heartbeat_interval_seconds,
                listener              => $controller->gp_realtime_pg_listener,
                logger                => $controller->app->log,
                poll_interval_seconds =>
                  $config->realtime_listener_poll_interval_seconds,
                reconnect_backoff_seconds =>
                  $config->realtime_listener_reconnect_backoff_seconds,
              );
            return $realtime_listener_supervisor;
        }
    );
    _configure_realtime_listener_lifecycle( $application, $config );

    return;
}

# The dispatcher counts a badge as the inbox does (ADR 0102). Forum
# registers it; an application built without it sends no badge snapshots.
# A helper is not a method, so can() would never find it: the renderer is
# asked.
sub _badge_counter ($controller) {
    return undef
      if !$controller->app->renderer->get_helper('gp_notification_dispatcher');

    return $controller->gp_notification_dispatcher;
}

sub _configure_static_assets ($application) {
    my $paths = $application->static->paths;
    push @{$paths},
      $application->home->rel_file('assets/css')->to_string,
      $application->home->rel_file('assets/img')->to_string,
      $application->home->rel_file('assets/js')->to_string;

    return;
}

# A response of min_compress_size bytes or more is gzipped for a client that
# accepts it, as Mojolicious::Renderer::respond would, with the headers it
# writes: Vary for every such response, Content-Encoding when it is encoded.
# The renderer's own compression is off so the page is not encoded twice.
# One deflate stream serves the process, reset between responses: zlib
# allocates its 256 KB of state once rather than for every page.
sub _configure_compression ($application) {
    my $renderer = $application->renderer;
    $renderer->compress(0);
    my $minimum = $renderer->min_compress_size;

    $application->hook(
        after_render => sub {
            my ( $controller, $output ) = @_;

            return if length ${$output} < $minimum;

            my $headers = $controller->res->headers;
            $headers->append( Vary => 'Accept-Encoding' );
            return
              if ( $controller->req->headers->accept_encoding // q{} ) !~
              /gzip/imsx;
            return if $headers->content_encoding;

            $headers->content_encoding('gzip');
            ${$output} = _gzip( ${$output} );

            return;
        }
    );

    return;
}

my $DEFLATE;

sub _gzip ($plain) {
    if ( !$DEFLATE ) {
        ($DEFLATE) = Compress::Raw::Zlib::Deflate->new(
            -AppendOutput => 1,
            -Level        => $GZIP_LEVEL,
            -WindowBits   => WANT_GZIP,
        );
        die "zlib refused a deflate stream\n" if !$DEFLATE;
    }

    my $compressed = q{};
    $DEFLATE->deflateReset;
    my $status = $DEFLATE->deflate( $plain, $compressed );
    die "gzip failed: $status\n" if $status != Z_OK;
    $status = $DEFLATE->flush($compressed);
    die "gzip failed: $status\n" if $status != Z_OK;

    return $compressed;
}

# A pre-forking server's manager renders the main pages once before it
# forks: every worker then starts with the templates compiled, the
# statements prepared and the memos filled, where each used to pay for
# them on its first requests (146 ms for the home page against 16 after).
# A single-process server (daemon, morbo, the test client) is not warmed:
# it has no workers to inherit the work.
sub _configure_warmup ( $application, $config ) {
    return if !$config->warmup_enabled;

    $application->hook(
        before_server_start => sub ( $server, $app ) {
            return if !$server->isa('Mojo::Server::Prefork');

            my $report = GPForum::Web::Warmup->new( application => $app )->run;
            $app->log->info( GPForum::Web::Warmup->describe($report) );
        }
    );

    return;
}

sub _configure_realtime_listener_lifecycle {
    my ( $application, $config ) = @_;

    return if !$config->realtime_listener_enabled;

    $application->hook(
        before_dispatch => sub {
            my ($controller) = @_;

            # The manager warming its pages must not open the listener's
            # connection: the workers would inherit it.
            return if $controller->stash('gpforum.warming');

            $controller->gp_realtime_listener_supervisor->start;
        }
    );

    return;
}

1;
