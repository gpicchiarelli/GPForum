package GPForum::Service::Operations::DeployChecklistDrill;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use IPC::Open3    qw(open3);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base;
use Mojo::File qw(path);
use Symbol     qw(gensym);

use GPForum::Service::Operations::DeployContract qw(
  deploy_match_text
  deploy_nginx_checks
  deploy_unit_checks
);

our $VERSION = '0.001';

const my $EXIT_FAILURE     => 1;
const my $EXIT_SHIFT       => 8;
const my $REPO_ROOT_MARKER => 'cpanfile';
const my $ROOT_WALK_LIMIT  => 8;
const my @STUB_SCRIPTS => (
    'script/gpforum-carton',      'script/gpforum-os-preflight',
    'bin/gpforum',                'bin/gpforum-outbox-dispatch',
    'bin/gpforum-scheduled-jobs', 'bin/hypnotoad',
);
const my $RESIDUAL_HOST =>
'Installing units into a live systemd, nginx reload on a host vhost, Hypnotoad process start, and TLS termination remain operator steps beyond this drill.';
const my $RESIDUAL_BETA => 'This drill does not claim private-beta readiness.';

has repo_root => sub { return _detect_repo_root() };

sub run {
    my ( $self, $options ) = @_;

    my $evidence = _base_evidence($options);
    my $ok       = eval {
        $self->_execute($evidence);
        return 1;
    };
    if ( !$ok ) {
        $evidence->{status} = 'fail';
        $evidence->{error}  = _trim_error($EVAL_ERROR);
    }
    $evidence->{status} ||= _status_from_checks($evidence);
    $self->_cleanup($evidence);

    return $evidence;
}

sub format_evidence {
    my ( $self, $evidence, $format ) = @_;

    return encode_json($evidence) . "\n" if $format eq 'json';

    return _human_evidence($evidence);
}

sub exit_status {
    my ( $self, $evidence ) = @_;

    my $status = $evidence->{status} // q{};
    return 0 if $status eq 'pass' || $status eq 'degraded';

    return $EXIT_FAILURE;
}

sub _execute {
    my ( $self, $evidence ) = @_;

    my $root = $self->repo_root;
    croak 'repository root not found' if !_has_text($root);

    my @unit_results  = map { _check_file( $root, $_ ) } deploy_unit_checks();
    my @nginx_results = map { _check_file( $root, $_ ) } deploy_nginx_checks();
    my $host          = $self->_host_validation( $root, $evidence );

    $evidence->{deploy_checklist} = {
        mode            => 'static_plus_host',
        repo_root       => $root,
        systemd_units   => \@unit_results,
        nginx_configs   => \@nginx_results,
        host_validation => $host,
        optional_tools  => _optional_tool_probe(),
    };

    return;
}

sub _host_validation {
    my ( $self, $root, $evidence ) = @_;

    my $workspace = tempdir( 'gpforum-deploy-host-XXXXXX', TMPDIR => 1 );
    $evidence->{_workspace} = $workspace;
    _prepare_host_workspace($workspace);

    my $systemd = _systemd_verify_phase( $root, $workspace );
    my $nginx   = _nginx_test_phase( $root, $workspace );

    return {
        status  => _host_status( $systemd, $nginx ),
        systemd => $systemd,
        nginx   => $nginx,
    };
}

sub _prepare_host_workspace {
    my ($workspace) = @_;

    path( $workspace, 'etc' )->make_path;
    path( $workspace, 'etc', 'gpforum.env' )->spew(q{});
    path( $workspace, 'attachments' )->make_path;
    path( $workspace, 'assets' )->make_path;
    for my $relative (@STUB_SCRIPTS) {
        my $target = path( $workspace, $relative );
        $target->dirname->make_path;
        $target->spew("#!/bin/sh\nexit 0\n");
        chmod oct('0755'), $target->to_string
          or croak "failed to chmod $relative: $ERRNO";
    }

    return;
}

sub _systemd_verify_phase {
    my ( $root, $workspace ) = @_;

    my $binary = _which('systemd-analyze');
    return _skipped_tool( 'systemd-analyze',
        'systemd-analyze not on PATH; static unit text checks only' )
      if !_has_text($binary);

    my @units;
    for my $check ( deploy_unit_checks() ) {
        push @units, _verify_one_unit( $root, $workspace, $binary, $check );
    }

    return {
        status    => _phase_status_from_units( \@units ),
        available => \1,
        tool      => $binary,
        mode      => 'rendered_sample_units',
        units     => \@units,
    };
}

sub _verify_one_unit {
    my ( $root, $workspace, $binary, $check ) = @_;

    my $source   = path( $root, $check->{path} )->to_string;
    my $rendered = path( $workspace, 'units', $check->{name} )->to_string;
    path($rendered)->dirname->make_path;
    _render_unit_for_verify( $source, $rendered, $workspace );
    my $capture = _capture_command( [ $binary, 'verify', $rendered ] );

    return {
        name     => $check->{name},
        path     => $check->{path},
        status   => $capture->{ok} ? 'pass' : 'fail',
        exit     => $capture->{exit},
        output   => _trim_output( $capture->{output} ),
        rendered => $rendered,
    };
}

sub _render_unit_for_verify {
    my ( $source, $destination, $workspace ) = @_;

    my $text  = path($source)->slurp;
    my $user  = _current_user_name();
    my $group = _current_group_name();
    $text =~ s{/opt/gpforum}{$workspace}gmsx;
    $text =~ s{/etc/gpforum/gpforum[.]env}{$workspace/etc/gpforum.env}gmsx;
    $text =~ s{^User=[^\n]*}{User=$user}msx;
    $text =~ s{^Group=[^\n]*}{Group=$group}msx;
    $text =~ s{^Environment=GPFORUM_RUNTIME_LISTEN=[^\n]*}
              {Environment=GPFORUM_RUNTIME_LISTEN=http://127.0.0.1:8080}msx;
    path($destination)->spew($text);

    return;
}

sub _current_user_name {
    my $user = getpwuid $EFFECTIVE_USER_ID;
    return $user if _has_text($user);
    return 'nobody';
}

sub _current_group_name {
    my $group = getgrgid $EFFECTIVE_GROUP_ID;
    return $group if _has_text($group);
    return 'nogroup';
}

sub _nginx_test_phase {
    my ( $root, $workspace ) = @_;

    my $binary = _which('nginx');
    return _skipped_tool( 'nginx',
        'nginx not on PATH; static nginx template checks only' )
      if !_has_text($binary);

    my @configs;
    for my $check ( deploy_nginx_checks() ) {
        push @configs, _nginx_test_one( $root, $workspace, $binary, $check );
    }

    return {
        status    => _phase_status_from_units( \@configs ),
        available => \1,
        tool      => $binary,
        mode      => 'rendered_sample_nginx_t',
        configs   => \@configs,
    };
}

sub _nginx_test_one {
    my ( $root, $workspace, $binary, $check ) = @_;

    my $source = path( $root, $check->{path} )->to_string;
    my $prefix = path( $workspace, 'nginx', $check->{name} )->to_string;
    path($prefix)->make_path;
    my $included = path( $prefix, 'site.conf' )->to_string;
    my $main     = path( $prefix, 'nginx.conf' )->to_string;
    _render_nginx_site( $source, $included, $workspace );
    _write_nginx_main( $main, $included, $prefix );
    my $capture =
      _capture_command( [ $binary, '-t', '-c', $main, '-p', $prefix ] );

    return {
        name     => $check->{name},
        path     => $check->{path},
        status   => $capture->{ok} ? 'pass' : 'fail',
        exit     => $capture->{exit},
        output   => _trim_output( $capture->{output} ),
        rendered => $main,
    };
}

sub _render_nginx_site {
    my ( $source, $destination, $workspace ) = @_;

    my $text   = path($source)->slurp;
    my $assets = path( $workspace, 'assets' )->to_string;
    my $attach = path( $workspace, 'attachments' )->to_string;
    $text =~ s{root\s+/opt/gpforum;}{root $assets;}gmsx;
    $text =~ s{alias\s+/srv/gpforum/attachments/;}{alias $attach/;}gmsx;

    # Sample templates listen on 80. Distro nginx -t still opens listen
    # sockets, so non-root hosts need an unprivileged port for the probe.
    $text =~ s{listen\s+80;}{listen 127.0.0.1:18080;}gmsx;
    path($destination)->spew($text);

    return;
}

sub _write_nginx_main {
    my ( $main, $included, $prefix ) = @_;

    my $pid   = path( $prefix, 'nginx.pid' )->to_string;
    my $error = path( $prefix, 'error.log' )->to_string;
    my $tmp   = path( $prefix, 'tmp' )->to_string;
    path($tmp)->make_path;
    for my $subdir (qw(body proxy fastcgi uwsgi scgi)) {
        path( $tmp, $subdir )->make_path;
    }

    # Distro nginx binaries often compile --http-*-temp-path under
    # /var/lib/nginx (root-owned). Override them into the throwaway
    # prefix so non-root `nginx -t -p` succeeds on developer/CI hosts.
    my $body    = path( $tmp, 'body' )->to_string;
    my $proxy   = path( $tmp, 'proxy' )->to_string;
    my $fastcgi = path( $tmp, 'fastcgi' )->to_string;
    my $uwsgi   = path( $tmp, 'uwsgi' )->to_string;
    my $scgi    = path( $tmp, 'scgi' )->to_string;
    path($main)->spew(<<"CONF");
worker_processes 1;
error_log $error;
pid $pid;
events {
    worker_connections 64;
}
http {
    access_log off;
    client_body_temp_path $body;
    proxy_temp_path $proxy;
    fastcgi_temp_path $fastcgi;
    uwsgi_temp_path $uwsgi;
    scgi_temp_path $scgi;
    include $included;
}
CONF

    return;
}

sub _skipped_tool {
    my ( $name, $reason ) = @_;

    return {
        status    => 'skipped',
        available => \0,
        tool      => $name,
        reason    => $reason,
    };
}

sub _host_status {
    my ( $systemd, $nginx ) = @_;

    for my $phase ( $systemd, $nginx ) {
        return 'fail' if ( $phase->{status} // q{} ) eq 'fail';
    }
    for my $phase ( $systemd, $nginx ) {
        return 'degraded' if ( $phase->{status} // q{} ) eq 'skipped';
    }

    return 'pass';
}

sub _phase_status_from_units {
    my ($units) = @_;

    for my $unit ( @{$units} ) {
        return 'fail' if ( $unit->{status} // q{} ) ne 'pass';
    }

    return 'pass';
}

sub _capture_command {
    my ($command) = @_;

    my $stderr = gensym;
    my $pid    = open3( my $stdin, my $stdout, $stderr, @{$command} );
    close $stdin or croak 'failed to close host-check stdin';
    my $output = _slurp_handle($stdout) . _slurp_handle($stderr);
    waitpid $pid, 0;
    my $exit = $CHILD_ERROR >> $EXIT_SHIFT;

    return {
        ok     => ( $CHILD_ERROR == 0 ) ? 1 : 0,
        exit   => $exit,
        output => $output,
    };
}

sub _slurp_handle {
    my ($handle) = @_;

    my $output = q{};
    while ( my $line = <$handle> ) {
        $output .= $line;
    }
    close $handle or croak 'failed to close host-check handle';

    return $output;
}

sub _cleanup {
    my ( $self, $evidence ) = @_;

    my $workspace = delete $evidence->{_workspace};
    return if !_has_text($workspace);
    require File::Path;
    File::Path::remove_tree($workspace);

    return;
}

sub _check_file {
    my ( $root, $check ) = @_;

    my $absolute = path( $root, $check->{path} )->to_string;
    my $result   = {
        path    => $check->{path},
        name    => $check->{name},
        exists  => ( -f $absolute ) ? \1 : \0,
        status  => 'fail',
        matched => [],
        missing => [],
    };
    if ( !-f $absolute ) {
        push @{ $result->{missing} }, 'file missing';
        return $result;
    }

    my $match = deploy_match_text( path($absolute)->slurp, $check );
    $result->{matched} = $match->{matched_labels};
    $result->{missing} = $match->{missing_labels};
    $result->{status}  = $match->{status};

    return $result;
}

sub _optional_tool_probe {
    my $systemd = _which('systemd-analyze');
    my $nginx   = _which('nginx');

    return {
        systemd_analyze => {
            available => $systemd ? \1 : \0,
            path      => $systemd,
            note      => $systemd
            ? 'present on PATH; drill runs systemd-analyze verify on rendered sample units'
            : 'not on PATH; static unit text checks only (host verify skipped)',
        },
        nginx => {
            available => $nginx ? \1 : \0,
            path      => $nginx,
            note      => $nginx
            ? 'present on PATH; drill runs nginx -t on rendered sample configs'
            : 'not on PATH; static nginx template checks only (host nginx -t skipped)',
        },
    };
}

sub _which {
    my ($name) = @_;

    for my $dir ( split /:/msx, ( $ENV{PATH} // q{} ) ) {
        my $candidate = path( $dir, $name )->to_string;
        return $candidate if -x $candidate;
    }

    return;
}

sub _detect_repo_root {
    my $start  = path(__FILE__)->realpath->dirname;
    my $cursor = $start;
    for ( 1 .. $ROOT_WALK_LIMIT ) {
        return $cursor->to_string
          if -f $cursor->child($REPO_ROOT_MARKER)->to_string;
        $cursor = $cursor->dirname;
    }

    return path(q{.})->realpath->to_string;
}

sub _base_evidence {
    my ($options) = @_;

    return {
        status         => undef,
        drill          => 'deploy_checklist',
        residual_gaps  => [ $RESIDUAL_HOST, $RESIDUAL_BETA ],
        format_hint    => $options->{format},
        keep_workspace => $options->{keep_workspace} ? \1 : \0,
    };
}

sub _status_from_checks {
    my ($evidence) = @_;

    my $checklist = $evidence->{deploy_checklist} // {};
    return 'fail' if !_static_groups_pass($checklist);
    return _host_overall_status( $checklist->{host_validation} // {} );
}

sub _static_groups_pass {
    my ($checklist) = @_;

    for my $group (qw(systemd_units nginx_configs)) {
        for my $item ( @{ $checklist->{$group} // [] } ) {
            return 0 if ( $item->{status} // q{} ) ne 'pass';
        }
    }

    return 1;
}

sub _host_overall_status {
    my ($host) = @_;

    my $status = $host->{status} // 'pass';
    return 'fail'     if $status eq 'fail';
    return 'degraded' if $status eq 'degraded';

    return 'pass';
}

sub _human_evidence {
    my ($evidence) = @_;

    my $checklist = $evidence->{deploy_checklist} // {};
    my $host      = $checklist->{host_validation} // {};
    my @lines =
      ( 'staging-drill-deploy status=' . ( $evidence->{status} // 'fail' ) );
    for my $item (
        @{ $checklist->{systemd_units} // [] },
        @{ $checklist->{nginx_configs} // [] }
      )
    {
        push @lines, "$item->{name} status=$item->{status}";
    }
    push @lines,
        'host_validation status='
      . ( $host->{status} // 'missing' )
      . ' systemd='
      . ( $host->{systemd}{status} // 'missing' )
      . ' nginx='
      . ( $host->{nginx}{status} // 'missing' );
    if ( _has_text( $evidence->{error} ) ) {
        push @lines, 'error=' . $evidence->{error};
    }

    return join( "\n", @lines ) . "\n";
}

sub _trim_output {
    my ($output) = @_;

    $output = "$output";
    $output =~ s/\s+\z//msx;
    return $output;
}

sub _trim_error {
    my ($error) = @_;

    $error = "$error";
    $error =~ s/\s+\z//msx;

    return $error;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DeployChecklistDrill - Static plus host nginx/systemd checks.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $evidence =
      GPForum::Service::Operations::DeployChecklistDrill->new->run({});

=head1 DESCRIPTION

Always verifies deploy unit and nginx templates exist and contain key
directives. When C<systemd-analyze> is on C<PATH>, also renders sample units
into a temp tree (stub ExecStart paths, current user) and runs
C<systemd-analyze verify>. When C<nginx> is on C<PATH>, renders a wrapper
config around the sample site snippets (with client/proxy temp paths under
the throwaway prefix so non-root distro nginx binaries can run C<nginx -t>)
and runs C<nginx -t>. Missing host tools mark those phases C<skipped> and
the overall evidence C<degraded> while static checks still pass. Does not
start Hypnotoad or claim private-beta readiness.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
