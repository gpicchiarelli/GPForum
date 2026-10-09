# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DeployChecklistDrill;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use GPForum::X::Config;
use IPC::Open3    qw(open3);
use JSON::MaybeXS qw(encode_json);
use List::Util    qw(any);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);
use Symbol     qw(gensym);

use GPForum::Service::Operations::DeployContract qw(
  deploy_match_text
  deploy_nginx_checks
  deploy_unit_checks
);
use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);

our $VERSION = '0.001';

const my $EXIT_FAILURE     => 1;
const my $EXIT_SHIFT       => 8;
const my $REPO_ROOT_MARKER => 'cpanfile';
const my $ROOT_WALK_LIMIT  => 8;
const my @STUB_SCRIPTS => (
    'script/gpforum-carton',      'script/os-preflight',
    'bin/gpforum',                'bin/gpforum-outbox-dispatch',
    'bin/gpforum-scheduled-jobs', 'bin/hypnotoad',
);
const my $RESIDUAL_HOST =>
'Installing units into a live systemd, nginx reload on a host vhost, Hypnotoad process start, and TLS termination remain operator steps beyond this drill.';
const my $RESIDUAL_BETA => 'This drill does not claim private-beta readiness.';

has repo_root => sub { return _detect_repo_root() };

sub run ( $self, $options ) {
    my $evidence = {
        check          => 'deploy_checklist',
        status         => undef,
        drill          => 'deploy_checklist',
        residual_gaps  => [ $RESIDUAL_HOST, $RESIDUAL_BETA ],
        format_hint    => $options->{format},
        keep_workspace => $options->{keep_workspace} ? \1 : \0,
    };
    try {
        $self->_execute($evidence);
    }
    catch ($error) {
        $evidence->{status} = 'fail';
        $evidence->{error}  = _trimmed($error);
    };
    $evidence->{status} ||= _status_from_checks($evidence);
    $self->_cleanup($evidence);

    return evidence_finalize($evidence);
}

sub format_evidence ( $self, $evidence, $format ) {
    return encode_json($evidence) . "\n" if $format eq 'json';

    return _human_evidence($evidence);
}

sub exit_status ( $self, $evidence ) {
    my $status = $evidence->{status} // q{};
    return 0 if $status eq 'pass' || $status eq 'degraded';

    return $EXIT_FAILURE;
}

sub _execute ( $self, $evidence ) {
    my $root = $self->repo_root;
    if ( !_has_text($root) ) {
        GPForum::X::Config->throw( message => 'repository root not found' );
    }

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

sub _host_validation ( $self, $root, $evidence ) {
    my $workspace = tempdir( 'gpforum-deploy-host-XXXXXX', TMPDIR => 1 );
    $evidence->{_workspace} = $workspace;
    _prepare_host_workspace($workspace);

    my $systemd = _systemd_verify_phase( $root, $workspace );
    my $nginx   = _nginx_test_phase( $root, $workspace );

    my @statuses = map { $_->{status} // q{} } $systemd, $nginx;
    my $status =
        ( any { $_ eq 'fail' } @statuses )    ? 'fail'
      : ( any { $_ eq 'skipped' } @statuses ) ? 'degraded'
      :                                         'pass';

    return { status => $status, systemd => $systemd, nginx => $nginx };
}

sub _prepare_host_workspace ($workspace) {
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

sub _systemd_verify_phase ( $root, $workspace ) {
    my $binary = _which('systemd-analyze');
    return _skipped_tool( 'systemd-analyze',
        'systemd-analyze not on PATH; static unit text checks only' )
      if !_has_text($binary);

    my @units;
    for my $check ( deploy_unit_checks() ) {
        my $rendered = path( $workspace, 'units', $check->{name} )->to_string;
        path($rendered)->dirname->make_path;
        _render_unit_for_verify( path( $root, $check->{path} )->to_string,
            $rendered, $workspace );
        my $capture = _capture_command( [ $binary, 'verify', $rendered ] );
        push @units,
          {
            name     => $check->{name},
            path     => $check->{path},
            status   => $capture->{ok} ? 'pass' : 'fail',
            exit     => $capture->{exit},
            output   => _trimmed( $capture->{output} ),
            rendered => $rendered,
          };
    }

    return {
        status    => _phase_status_from_units( \@units ),
        available => \1,
        tool      => $binary,
        mode      => 'rendered_sample_units',
        units     => \@units,
    };
}

sub _render_unit_for_verify ( $source, $destination, $workspace ) {
    my $text  = path($source)->slurp;
    my $user  = getpwuid $EFFECTIVE_USER_ID;
    my $group = getgrgid $EFFECTIVE_GROUP_ID;
    if ( !_has_text($user) ) {
        $user = 'nobody';
    }
    if ( !_has_text($group) ) {
        $group = 'nogroup';
    }
    $text =~ s{/opt/gpforum}{$workspace}gmsx;
    $text =~ s{/etc/gpforum/gpforum[.]env}{$workspace/etc/gpforum.env}gmsx;
    $text =~ s{^User=[^\n]*}{User=$user}msx;
    $text =~ s{^Group=[^\n]*}{Group=$group}msx;
    $text =~ s{^Environment=GPFORUM_RUNTIME_LISTEN=[^\n]*}
              {Environment=GPFORUM_RUNTIME_LISTEN=http://127.0.0.1:8080}msx;
    path($destination)->spew($text);

    return;
}

sub _nginx_test_phase ( $root, $workspace ) {
    my $binary = _which('nginx');
    return _skipped_tool( 'nginx',
        'nginx not on PATH; static nginx template checks only' )
      if !_has_text($binary);

    # The TLS server block names the certificate certbot writes; nginx -t
    # loads it, so the probe gets a throwaway one of its own.
    my $tls = _throwaway_certificate($workspace);
    return _skipped_tool( 'nginx',
        'openssl not on PATH, or it failed; nginx -t needs a certificate for'
          . ' the TLS server block' )
      if !$tls;

    my @configs;
    for my $check ( deploy_nginx_checks() ) {
        my $prefix = path( $workspace, 'nginx', $check->{name} )->to_string;
        path($prefix)->make_path;
        my $included = path( $prefix, 'site.conf' )->to_string;
        my $main     = path( $prefix, 'nginx.conf' )->to_string;
        _render_nginx_site( path( $root, $check->{path} )->to_string,
            $included, $workspace, $tls );
        _write_nginx_main( $main, $included, $prefix );
        my $capture =
          _capture_command( [ $binary, '-t', '-c', $main, '-p', $prefix ] );
        push @configs,
          {
            name     => $check->{name},
            path     => $check->{path},
            status   => $capture->{ok} ? 'pass' : 'fail',
            exit     => $capture->{exit},
            output   => _trimmed( $capture->{output} ),
            rendered => $main,
          };
    }

    return {
        status    => _phase_status_from_units( \@configs ),
        available => \1,
        tool      => $binary,
        mode      => 'rendered_sample_nginx_t',
        configs   => \@configs,
    };
}

sub _render_nginx_site ( $source, $destination, $workspace, $tls ) {
    my $text   = path($source)->slurp;
    my $assets = path( $workspace, 'assets' )->to_string;
    my $attach = path( $workspace, 'attachments' )->to_string;
    $text =~ s{root\s+/opt/gpforum;}{root $assets;}gmsx;
    $text =~ s{alias\s+/srv/gpforum/attachments/;}{alias $attach/;}gmsx;

    # Sample templates listen on 80. Distro nginx -t still opens listen
    # sockets, so non-root hosts need an unprivileged port for the probe.
    $text =~ s{listen\s+80;}{listen 127.0.0.1:18080;}gmsx;
    $text =~ s{listen\s+443\s+ssl;}{listen 127.0.0.1:18443 ssl;}gmsx;
    $text =~ s{^[ \t]*listen\s+\[::\]:[^;]*;\n}{}gmsx;
    $text =~
      s{ssl_certificate\s+[^;]+;}{ssl_certificate $tls->{certificate};}gmsx;
    $text =~
      s{ssl_certificate_key\s+[^;]+;}{ssl_certificate_key $tls->{key};}gmsx;
    path($destination)->spew($text);

    return;
}

# A self-signed pair, valid for a day, in the drill's workspace: nginx -t
# opens the certificate a site names, and the one certbot writes is not on a
# CI runner or a developer's machine.
sub _throwaway_certificate ($workspace) {
    my $openssl = _which('openssl');
    return undef if !_has_text($openssl);

    my $directory = path( $workspace, 'tls' );
    $directory->make_path;
    my $certificate = $directory->child('fullchain.pem')->to_string;
    my $key         = $directory->child('privkey.pem')->to_string;
    my $capture     = _capture_command(
        [
            $openssl,   'req',        '-x509',   '-newkey',
            'rsa:2048', '-nodes',     '-keyout', $key,
            '-out',     $certificate, '-days',   '1',
            '-subj',    '/CN=localhost',
        ]
    );
    return undef if !$capture->{ok} || !-f $certificate || !-f $key;

    return { certificate => $certificate, key => $key };
}

sub _write_nginx_main ( $main, $included, $prefix ) {
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

sub _skipped_tool ( $name, $reason ) {
    return {
        status    => 'skipped',
        available => \0,
        tool      => $name,
        reason    => $reason,
    };
}

sub _phase_status_from_units ($units) {
    for my $unit ( @{$units} ) {
        return 'fail' if ( $unit->{status} // q{} ) ne 'pass';
    }

    return 'pass';
}

sub _capture_command ($command) {
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

sub _slurp_handle ($handle) {
    my $output = q{};
    while ( my $line = <$handle> ) {
        $output .= $line;
    }
    close $handle or croak 'failed to close host-check handle';

    return $output;
}

sub _cleanup ( $self, $evidence ) {
    my $workspace = delete $evidence->{_workspace};
    return if !_has_text($workspace);
    require File::Path;
    File::Path::remove_tree($workspace);

    return;
}

sub _check_file ( $root, $check ) {
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

sub _which ($name) {
    for my $dir ( split /:/msx, ( $ENV{PATH} // q{} ) ) {
        my $candidate = path( $dir, $name )->to_string;
        return $candidate if -x $candidate;
    }

    return undef;
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

# Every static check must pass; then the host validation decides between
# pass and degraded, or fails the drill.
sub _status_from_checks ($evidence) {
    my $checklist = $evidence->{deploy_checklist} // {};
    my @static =
      map { @{ $checklist->{$_} // [] } } qw(systemd_units nginx_configs);
    return 'fail' if any { ( $_->{status} // q{} ) ne 'pass' } @static;

    my $host = ( $checklist->{host_validation} // {} )->{status} // 'pass';
    return $host eq 'fail' || $host eq 'degraded' ? $host : 'pass';
}

sub _human_evidence ($evidence) {
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

sub _trimmed ($text) {
    return "$text" =~ s/\s+\z//msxr;
}

sub _has_text ($value) {
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

The templates and the directives each must contain come from
L<GPForum::Service::Operations::DeployContract>. The
C<staging-drill-attachments> command runs this drill as its deploy phase.
Rendered files go to a temporary workspace that is removed when the drill
ends.

=head1 SUBROUTINES/METHODS

=head2 run

Takes a hash reference of options; C<format> and C<keep_workspace> are
copied into the evidence (as C<format_hint> and C<keep_workspace>), nothing
else is read. Runs the drill against C<repo_root> and returns its evidence
hash reference, finalized by
L<GPForum::Service::Operations::EvidenceMeta/evidence_finalize>: C<check>
and C<drill> (both C<deploy_checklist>), C<status>, C<residual_gaps>,
C<secrets_redacted>, C<private_beta_claimed> (0) and C<deploy_checklist>,
which holds C<repo_root>, the per-file results C<systemd_units> and
C<nginx_configs> (C<exists>, C<matched>, C<missing>, C<status>),
C<host_validation> (its C<status> and the C<systemd> and C<nginx> phases,
each C<pass>, C<fail> or C<skipped>) and C<optional_tools>. C<status> is
C<fail> when a static check fails or a host check fails, C<degraded> when
the static checks pass but a host tool is missing, C<pass> otherwise. It
does not die: an error becomes C<< status => 'fail' >> with C<error> set,
and C<deploy_checklist> absent.

=head2 format_evidence

Takes an evidence hash reference and a format. Returns it as one line of
JSON when the format is C<json>; otherwise as text: a
C<staging-drill-deploy status=...> line, one C<NAME status=...> line per
unit and nginx file, a C<host_validation> line with the C<systemd> and
C<nginx> statuses, and an C<error=> line when there is one. Each form ends
with a newline.

=head2 exit_status

Takes an evidence hash reference. Returns 0 when its C<status> is C<pass>
or C<degraded>, 1 otherwise.

=head1 DIAGNOSTICS

C<run> reports, as C<error>: C<repository root not found> when C<repo_root>
is empty; C<failed to chmod PATH>, C<failed to close host-check stdin> and
C<failed to close host-check handle> with the system error; and an error
from L<IPC::Open3> or L<Mojo::File> when a tool cannot be started or a
template cannot be read.

=head1 CONFIGURATION AND ENVIRONMENT

C<PATH> is searched for C<systemd-analyze> and C<nginx>. The workspace is
created under the system temporary directory (C<TMPDIR>). C<repo_root>
defaults to the nearest directory holding a C<cpanfile>, walking up at most
eight levels from this module, else the current directory.

=head1 DEPENDENCIES

L<Const::Fast>, L<File::Path>, L<File::Temp>, L<IPC::Open3>,
L<JSON::MaybeXS>, L<Mojo::Base>, L<Mojo::File>, L<Symbol>,
L<GPForum::Service::Operations::DeployContract>,
L<GPForum::Service::Operations::EvidenceMeta>; optionally
C<systemd-analyze> and C<nginx>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

C<keep_workspace> is recorded in the evidence but not honoured: the
workspace is always removed. When a host tool is present, a missing
template makes the whole run fail with the read error instead of a
per-file result. Installing units, reloading nginx, starting Hypnotoad and
TLS remain operator steps, as the residual gaps say.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
