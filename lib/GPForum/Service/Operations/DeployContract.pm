# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::DeployContract;

use v5.40;

use Const::Fast;
use Exporter qw(import);

our $VERSION = '0.001';

our @EXPORT_OK = qw(
  deploy_unit_checks
  deploy_nginx_checks
  deploy_host_unit_checks
  deploy_match_text
);

const my @UNIT_CHECKS => (
    {
        path       => 'deploy/systemd/gpforum.service',
        name       => 'gpforum.service',
        must_match => [
            qr/^User=gpforum\s*$/msx,
            qr/^EnvironmentFile=\/etc\/gpforum\/gpforum[.]env\s*$/msx,
            qr/^Environment=GPFORUM_LOG_PATH=\S+\s*$/msx,
qr{^ExecStart=.*/script/gpforum-carton\s+exec\s+hypnotoad\s+.*/bin/gpforum\s*$}msx,
        ],
        labels => [
            'User=gpforum',     'EnvironmentFile',
            'GPFORUM_LOG_PATH', 'ExecStart via gpforum-carton'
        ],
    },
    {
        path       => 'deploy/systemd/gpforum-unix-socket.service',
        name       => 'gpforum-unix-socket.service',
        must_match => [
            qr/^User=gpforum\s*$/msx,
            qr/^EnvironmentFile=\/etc\/gpforum\/gpforum[.]env\s*$/msx,
            qr/^Environment=GPFORUM_LOG_PATH=\S+\s*$/msx,
qr{^ExecStart=.*/script/gpforum-carton\s+exec\s+hypnotoad\s+.*/bin/gpforum\s*$}msx,
        ],
        labels => [
            'User=gpforum',     'EnvironmentFile',
            'GPFORUM_LOG_PATH', 'ExecStart via gpforum-carton'
        ],
    },
    {
        path       => 'deploy/systemd/gpforum-outbox.service',
        name       => 'gpforum-outbox.service',
        must_match => [
            qr/^User=gpforum\s*$/msx,
            qr/^EnvironmentFile=\/etc\/gpforum\/gpforum[.]env\s*$/msx,
            qr/^Environment=GPFORUM_LOG_PATH=\S+\s*$/msx,
            qr{^ExecStart=.*/script/gpforum-carton\s+exec\s+}msx,
        ],
        labels => [
            'User=gpforum',     'EnvironmentFile',
            'GPFORUM_LOG_PATH', 'ExecStart via gpforum-carton'
        ],
    },
    {
        path       => 'deploy/systemd/gpforum-scheduled-jobs.service',
        name       => 'gpforum-scheduled-jobs.service',
        must_match => [
            qr/^User=gpforum\s*$/msx,
            qr/^EnvironmentFile=\/etc\/gpforum\/gpforum[.]env\s*$/msx,
            qr/^Environment=GPFORUM_LOG_PATH=\S+\s*$/msx,
            qr{^ExecStart=.*/script/gpforum-carton\s+exec\s+}msx,
        ],
        labels => [
            'User=gpforum',     'EnvironmentFile',
            'GPFORUM_LOG_PATH', 'ExecStart via gpforum-carton'
        ],
    },
);

const my @NGINX_CHECKS => (
    {
        path       => 'deploy/nginx/gpforum.conf',
        name       => 'gpforum.conf',
        must_match => [
            qr/upstream\s+gpforum_backend\s*[{]/msx,
            qr/server\s+127[.]0[.]0[.]1:8080;/msx,
            qr{location\s+/internal-attachments/}msx,
            qr/listen\s+443\s+ssl;/msx,
            qr/ssl_certificate\s+\S+;/msx,
            qr{return\s+301\s+https://}msx,
        ],
        labels => [
            'upstream gpforum_backend',
            'upstream 127.0.0.1:8080',
            'internal-attachments',
            'TLS listener',
            'certificate configured',
            'plain HTTP redirected',
        ],
    },
    {
        path       => 'deploy/nginx/gpforum-unix-socket.conf',
        name       => 'gpforum-unix-socket.conf',
        must_match => [
            qr/upstream\s+gpforum_unix_backend\s*[{]/msx,
            qr{server\s+unix:/run/gpforum/gpforum[.]sock;}msx,
            qr{location\s+/internal-attachments/}msx,
            qr/listen\s+443\s+ssl;/msx,
            qr/ssl_certificate\s+\S+;/msx,
            qr{return\s+301\s+https://}msx,
        ],
        labels => [
            'upstream gpforum_unix_backend',
            'unix socket upstream',
            'internal-attachments',
            'TLS listener',
            'certificate configured',
            'plain HTTP redirected',
        ],
    },
);

const my %HOST_UNIT_NAMES => map { $_ => 1 } qw(
  gpforum.service
  gpforum-outbox.service
  gpforum-scheduled-jobs.service
);

sub deploy_unit_checks {
    return @UNIT_CHECKS;
}

sub deploy_nginx_checks {
    return @NGINX_CHECKS;
}

sub deploy_host_unit_checks {
    return grep { exists $HOST_UNIT_NAMES{ $_->{name} } } @UNIT_CHECKS;
}

sub deploy_match_text ( $text, $check ) {
    $text  //= q{};
    $check //= {};

    my @patterns = @{ $check->{must_match} // [] };
    my @labels   = @{ $check->{labels}     // [] };
    my @matched;
    my @missing;
    for my $index ( 0 .. $#patterns ) {
        my $label = $labels[$index] // "pattern_$index";
        if ( $text =~ $patterns[$index] ) {
            push @matched, $label;
        }
        else {
            push @missing, $label;
        }
    }

    return {
        status         => @missing ? 'fail' : 'pass',
        matched_labels => \@matched,
        missing_labels => \@missing,
        checked_labels => [@labels],
        name           => $check->{name},
        path           => $check->{path},
    };
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::DeployContract - Shared deploy unit/nginx contracts.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Service::Operations::DeployContract qw(
      deploy_unit_checks
      deploy_nginx_checks
      deploy_host_unit_checks
      deploy_match_text
    );

    my $result = deploy_match_text( $unit_text, $check );

=head1 DESCRIPTION

Single source of truth for systemd unit and nginx template contracts used by
the deploy checklist drill and live staging-host verify observers. Host unit
observe covers C<gpforum.service>, C<gpforum-outbox.service>, and
C<gpforum-scheduled-jobs.service>. Matching never installs, enables, or
reloads services, and never claims private-beta readiness.

A check is a hash reference with C<path> (the template, relative to the
repository root), C<name> (the installed file name), C<must_match> (the
patterns the file must contain) and C<labels> (one name per pattern, for
the report). Every unit must run as C<gpforum>, read
C</etc/gpforum/gpforum.env>, set C<GPFORUM_LOG_PATH> and start through
C<script/gpforum-carton exec> (the two web units through C<hypnotoad> and
C<bin/gpforum>). Every nginx site must define its upstream (TCP
C<127.0.0.1:8080>, or the C</run/gpforum/gpforum.sock> socket), the
C</internal-attachments/> location, a TLS listener on 443 with a
certificate, and a redirect of plain HTTP to HTTPS. The functions are
exported on request only.

=head1 SUBROUTINES/METHODS

=head2 deploy_unit_checks

Returns the list of the four systemd unit checks: C<gpforum.service>,
C<gpforum-unix-socket.service>, C<gpforum-outbox.service> and
C<gpforum-scheduled-jobs.service>, from F<deploy/systemd/>.

=head2 deploy_nginx_checks

Returns the list of the two nginx checks: C<gpforum.conf> and
C<gpforum-unix-socket.conf>, from F<deploy/nginx/>.

=head2 deploy_host_unit_checks

Returns the list of the unit checks for the units a host runs:
C<gpforum.service>, C<gpforum-outbox.service> and
C<gpforum-scheduled-jobs.service>, without the unix-socket variant.

=head2 deploy_match_text

Takes a file's text and a check (either may be undef). Returns a hash
reference with C<status> (C<pass> when every pattern matched, else
C<fail>), C<matched_labels>, C<missing_labels>, C<checked_labels>, and
the check's C<name> and C<path>. A pattern without a label is reported as
C<pattern_> and its index.

=head1 DIAGNOSTICS

None. A missing pattern is a C<missing_labels> entry and a C<fail>
status, never an error.

=head1 CONFIGURATION AND ENVIRONMENT

None. The callers read the files; this module only holds the patterns
and matches text.

=head1 DEPENDENCIES

L<Const::Fast>, L<Exporter>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The checks are the module's own read-only constants: a caller that wants
to change one must copy it first. The patterns test that a line is
present, not that the file is otherwise valid; the deploy checklist drill
runs C<systemd-analyze> and C<nginx -t> for that when they are on
C<PATH>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
