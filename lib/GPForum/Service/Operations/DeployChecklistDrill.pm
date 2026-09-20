package GPForum::Service::Operations::DeployChecklistDrill;

use strict;
use warnings;

use Carp          qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base;
use Mojo::File qw(path);

our $VERSION = '0.001';

const my $EXIT_FAILURE => 1;
const my $REPO_ROOT_MARKER => 'cpanfile';
const my @UNIT_CHECKS => (
    {
        path => 'deploy/systemd/gpforum.service',
        name => 'gpforum.service',
        must_match => [
            qr/^User=gpforum\s*$/msx,
            qr/^EnvironmentFile=\/etc\/gpforum\/gpforum[.]env\s*$/msx,
            qr{^ExecStart=.*/script/gpforum-carton\s+exec\s+hypnotoad\s+.*/bin/gpforum\s*$}msx,
        ],
        labels =>
          [ 'User=gpforum', 'EnvironmentFile', 'ExecStart via gpforum-carton' ],
    },
    {
        path => 'deploy/systemd/gpforum-unix-socket.service',
        name => 'gpforum-unix-socket.service',
        must_match => [
            qr/^User=gpforum\s*$/msx,
            qr/^EnvironmentFile=\/etc\/gpforum\/gpforum[.]env\s*$/msx,
            qr{^ExecStart=.*/script/gpforum-carton\s+exec\s+hypnotoad\s+.*/bin/gpforum\s*$}msx,
        ],
        labels =>
          [ 'User=gpforum', 'EnvironmentFile', 'ExecStart via gpforum-carton' ],
    },
    {
        path => 'deploy/systemd/gpforum-outbox.service',
        name => 'gpforum-outbox.service',
        must_match => [
            qr/^User=gpforum\s*$/msx,
            qr/^EnvironmentFile=\/etc\/gpforum\/gpforum[.]env\s*$/msx,
            qr{^ExecStart=.*/script/gpforum-carton\s+exec\s+}msx,
        ],
        labels =>
          [ 'User=gpforum', 'EnvironmentFile', 'ExecStart via gpforum-carton' ],
    },
    {
        path => 'deploy/systemd/gpforum-scheduled-jobs.service',
        name => 'gpforum-scheduled-jobs.service',
        must_match => [
            qr/^User=gpforum\s*$/msx,
            qr/^EnvironmentFile=\/etc\/gpforum\/gpforum[.]env\s*$/msx,
            qr{^ExecStart=.*/script/gpforum-carton\s+exec\s+}msx,
        ],
        labels =>
          [ 'User=gpforum', 'EnvironmentFile', 'ExecStart via gpforum-carton' ],
    },
);
const my @NGINX_CHECKS => (
    {
        path => 'deploy/nginx/gpforum.conf',
        name => 'gpforum.conf',
        must_match => [
            qr/upstream\s+gpforum_backend\s*[{]/msx,
            qr/server\s+127[.]0[.]0[.]1:8080;/msx,
            qr{location\s+/internal-attachments/}msx,
        ],
        labels =>
          [ 'upstream gpforum_backend', 'upstream 127.0.0.1:8080', 'internal-attachments' ],
    },
    {
        path => 'deploy/nginx/gpforum-unix-socket.conf',
        name => 'gpforum-unix-socket.conf',
        must_match => [
            qr/upstream\s+gpforum_unix_backend\s*[{]/msx,
            qr{server\s+unix:/run/gpforum/gpforum[.]sock;}msx,
            qr{location\s+/internal-attachments/}msx,
        ],
        labels => [
            'upstream gpforum_unix_backend',
            'unix socket upstream',
            'internal-attachments'
        ],
    },
);
const my $RESIDUAL_SYSTEMD =>
'systemd-analyze / nginx -t against a live host remain operator steps; this drill is a static template check.';
const my $RESIDUAL_HYPNOTOAD =>
'Hypnotoad process start, TLS termination, and env-file contents on a staging host are not executed here.';
const my $RESIDUAL_BETA =>
  'This drill does not claim private-beta readiness.';

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

    return $evidence;
}

sub format_evidence {
    my ( $self, $evidence, $format ) = @_;

    return encode_json($evidence) . "\n" if $format eq 'json';

    return _human_evidence($evidence);
}

sub exit_status {
    my ( $self, $evidence ) = @_;

    return 0 if ( $evidence->{status} // q{} ) eq 'pass';

    return $EXIT_FAILURE;
}

sub _execute {
    my ( $self, $evidence ) = @_;

    my $root = $self->repo_root;
    croak 'repository root not found' if !_has_text($root);

    my @unit_results;
    for my $check (@UNIT_CHECKS) {
        push @unit_results, _check_file( $root, $check );
    }
    my @nginx_results;
    for my $check (@NGINX_CHECKS) {
        push @nginx_results, _check_file( $root, $check );
    }

    $evidence->{deploy_checklist} = {
        mode           => 'static_template',
        repo_root      => $root,
        systemd_units  => \@unit_results,
        nginx_configs  => \@nginx_results,
        optional_tools => _optional_tool_probe(),
    };

    return;
}

sub _check_file {
    my ( $root, $check ) = @_;

    my $absolute = path( $root, $check->{path} )->to_string;
    my $result   = {
        path     => $check->{path},
        name     => $check->{name},
        exists   => ( -f $absolute ) ? \1 : \0,
        status   => 'fail',
        matched  => [],
        missing  => [],
    };
    if ( !-f $absolute ) {
        push @{ $result->{missing} }, 'file missing';
        return $result;
    }

    my $text = path($absolute)->slurp;
    my @matched;
    my @missing;
    for my $index ( 0 .. $#{ $check->{must_match} } ) {
        my $pattern = $check->{must_match}[$index];
        my $label   = $check->{labels}[$index] // "pattern_$index";
        if ( $text =~ $pattern ) {
            push @matched, $label;
        }
        else {
            push @missing, $label;
        }
    }
    $result->{matched} = \@matched;
    $result->{missing} = \@missing;
    $result->{status}  = @missing ? 'fail' : 'pass';

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
            ? 'present on PATH; live unit load still requires a host install'
            : 'not on PATH; static unit text checks only',
        },
        nginx => {
            available => $nginx ? \1 : \0,
            path      => $nginx,
            note      => $nginx
            ? 'present on PATH; nginx -t against installed configs is operator-side'
            : 'not on PATH; static nginx template checks only',
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
    my $start = path(__FILE__)->realpath->dirname;
    my $cursor = $start;
    for ( 1 .. 8 ) {
        return $cursor->to_string
          if -f $cursor->child($REPO_ROOT_MARKER)->to_string;
        $cursor = $cursor->dirname;
    }

    return path('.')->realpath->to_string;
}

sub _base_evidence {
    my ($options) = @_;

    return {
        status        => undef,
        drill         => 'deploy_checklist',
        residual_gaps =>
          [ $RESIDUAL_SYSTEMD, $RESIDUAL_HYPNOTOAD, $RESIDUAL_BETA ],
        format_hint => $options->{format},
    };
}

sub _status_from_checks {
    my ($evidence) = @_;

    my $checklist = $evidence->{deploy_checklist} // {};
    for my $group (qw(systemd_units nginx_configs)) {
        for my $item ( @{ $checklist->{$group} // [] } ) {
            return 'fail' if ( $item->{status} // q{} ) ne 'pass';
        }
    }

    return 'pass';
}

sub _human_evidence {
    my ($evidence) = @_;

    my $checklist = $evidence->{deploy_checklist} // {};
    my @lines =
      ( 'staging-drill-deploy status=' . ( $evidence->{status} // 'fail' ) );
    for my $item (
        @{ $checklist->{systemd_units} // [] },
        @{ $checklist->{nginx_configs} // [] }
      )
    {
        push @lines, "$item->{name} status=$item->{status}";
    }
    if ( _has_text( $evidence->{error} ) ) {
        push @lines, 'error=' . $evidence->{error};
    }

    return join( "\n", @lines ) . "\n";
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

GPForum::Service::Operations::DeployChecklistDrill - Static nginx/systemd template checks.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $evidence =
      GPForum::Service::Operations::DeployChecklistDrill->new->run({});

=head1 DESCRIPTION

Verifies deploy unit and nginx templates exist and contain key directives
(C<User>, C<EnvironmentFile>, C<ExecStart> via C<script/gpforum-carton>, nginx
upstream). Optional C<systemd-analyze> / C<nginx> binaries are probed but not
required. Does not start Hypnotoad or claim private-beta readiness.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
