# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Benchmark::ReverseProxy;

use v5.40;

use Carp       qw(croak);
use Exporter   qw(import);
use File::Temp qw(tempdir);
use Mojo::UserAgent;

use GPForum::Benchmark::Process qw(command_output find_binary free_port spawn);
use GPForum::X::Config;
use GPForum::X::Unavailable;

our $VERSION = '0.001';

our @EXPORT_OK = qw(proxy_command proxy_config resolve_proxy start_proxy);

# The proxy binary to run: the one asked for, or under auto the first of
# nginx and haproxy on PATH, with the version it reports.
sub resolve_proxy ($requested) {
    my @candidates = $requested eq 'auto' ? qw(nginx haproxy) : ($requested);

    for my $kind (@candidates) {
        my $binary = find_binary($kind);
        next if !$binary;

        my $version = command_output( $binary, '-v' );
        return {
            kind    => $kind,
            binary  => $binary,
            version => $version ne 'unknown' ? $version : $kind,
        };
    }

    GPForum::X::Config->throw(
        message => $requested eq 'auto'
        ? 'reverse proxy binary not found; searched nginx and haproxy'
        : "reverse proxy binary not found: $requested"
    );
}

# Starts the resolved proxy in front of the backend hypnotoad, on the
# frontend port asked for or a free one, and answers its runtime.
sub start_proxy ( $backend_runtime, $options, $proxy ) {
    my $directory     = tempdir( 'gpforum-reverse-proxy-XXXXXX', TMPDIR => 1 );
    my $frontend_port = $options->{frontend_port} || free_port();
    my %settings      = (
        kind          => $proxy->{kind},
        config_file   => "$directory/$proxy->{kind}.conf",
        pid_file      => "$directory/$proxy->{kind}.pid",
        log_file      => "$directory/$proxy->{kind}.log",
        frontend_port => $frontend_port,
        backend_port  => $backend_runtime->{port},
    );
    _write_config( \%settings );

    my @command =
      proxy_command( $proxy->{kind}, $proxy->{binary}, $settings{config_file} );
    my $pid = spawn(
        {
            name     => 'reverse proxy',
            log_file => $settings{log_file},
            session  => 1
        },
        @command
    );
    if ( !defined $pid ) {
        GPForum::X::Unavailable->throw(
            message => 'failed to fork reverse proxy benchmark process' );
    }

    return {
        process_pid  => $pid,
        directory    => $directory,
        kind         => $proxy->{kind},
        binary       => $proxy->{binary},
        version      => $proxy->{version},
        config_file  => $settings{config_file},
        pid_file     => $settings{pid_file},
        log_file     => $settings{log_file},
        base_url     => "http://127.0.0.1:$frontend_port",
        port         => $frontend_port,
        backend_url  => $backend_runtime->{base_url},
        backend_port => $backend_runtime->{port},
        command      => \@command,
        ua           => Mojo::UserAgent->new( request_timeout => 5 ),
    };
}

sub proxy_command ( $kind, $binary, $config_file ) {
    return $kind eq 'nginx'
      ? ( $binary, '-c', $config_file )
      : ( $binary, '-f', $config_file, '-db' );
}

sub proxy_config ($settings) {
    return $settings->{kind} eq 'nginx'
      ? _nginx_config($settings)
      : _haproxy_config($settings);
}

sub _write_config ($settings) {
    open my $handle, '>', $settings->{config_file}
      or croak "failed to write reverse proxy config $settings->{config_file}";
    print {$handle} proxy_config($settings)
      or croak "failed to write reverse proxy config $settings->{config_file}";
    close $handle
      or croak "failed to close reverse proxy config $settings->{config_file}";

    return;
}

sub _nginx_config ($settings) {
    return <<"NGINX";
daemon off;
worker_processes 1;
pid $settings->{pid_file};
error_log $settings->{log_file} warn;

events {
    worker_connections 256;
}

http {
    access_log off;

    server {
        listen 127.0.0.1:$settings->{frontend_port};

        location / {
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Host \$host;
            proxy_set_header X-Forwarded-Proto http;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header Connection "";
            proxy_pass http://127.0.0.1:$settings->{backend_port};
        }
    }
}
NGINX
}

sub _haproxy_config ($settings) {
    return <<"HAPROXY";
global
    maxconn 256
    pidfile $settings->{pid_file}

defaults
    mode http
    timeout connect 5s
    timeout client 30s
    timeout server 30s
    option forwardfor

frontend gpforum_frontend
    bind 127.0.0.1:$settings->{frontend_port}
    http-request set-header X-Forwarded-Proto http
    default_backend gpforum_backend

backend gpforum_backend
    server hypnotoad 127.0.0.1:$settings->{backend_port}
HAPROXY
}

1;

__END__

=head1 NAME

GPForum::Benchmark::ReverseProxy - The proxy the server benchmark measures through.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Benchmark::ReverseProxy qw(resolve_proxy start_proxy);

    my $proxy   = resolve_proxy('auto');
    my $runtime = start_proxy( $hypnotoad, { frontend_port => 0 }, $proxy );

=head1 DESCRIPTION

The nginx or HAProxy that L<GPForum::Command::HypnotoadBenchmark> puts in
front of hypnotoad with C<--reverse-proxy>: which binary to run, the
configuration it is given -- in the foreground, forwarding the
C<X-Forwarded-*> headers to the backend -- and starting it. Every function
is exported on request only.

=head1 SUBROUTINES/METHODS

=head2 resolve_proxy

Given C<auto>, C<nginx> or C<haproxy>, the C<kind>, C<binary> and C<version>
of the proxy to run; throws L<GPForum::X::Config> when no such binary is on
C<PATH>.

=head2 start_proxy

Given the backend runtime (C<port>, C<base_url>), the options
(C<frontend_port>) and a resolved proxy, writes its configuration in a
temporary directory, starts it in a session of its own and answers its
runtime: pid, files, C<base_url>, C<port>, C<command> and a user agent.

=head2 proxy_command

Given a kind, a binary and a configuration file, the command that runs the
proxy in the foreground.

=head2 proxy_config

Given C<kind>, C<pid_file>, C<log_file>, C<frontend_port> and
C<backend_port>, the configuration text.

=head1 DIAGNOSTICS

C<reverse proxy binary not found; searched nginx and haproxy>, C<reverse
proxy binary not found: KIND>, C<failed to write reverse proxy config FILE>,
C<failed to fork reverse proxy benchmark process>.

=head1 CONFIGURATION AND ENVIRONMENT

C<PATH>, searched for the proxy binary.

=head1 DEPENDENCIES

L<Exporter>, L<File::Temp>, L<Mojo::UserAgent>,
L<GPForum::Benchmark::Process>.

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
