# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::StatusReport;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
use JSON::MaybeXS ();
use Mojo::URL;

use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::HttpProbe;
use GPForum::Service::Operations::ReadinessFindings;

our $VERSION = '0.001';

# Where a development forum listens: what `gpforum start --foreground`
# gives Mojolicious's daemon.
const my $DEVELOPMENT_LISTEN => 'http://127.0.0.1:3000';

# A listen address that takes every interface is asked on the loopback.
const my %LOOPBACK => (
    q{*}      => '127.0.0.1',
    '0.0.0.0' => '127.0.0.1',
    q{[::]}   => '[::1]',
    q{::}     => '[::1]',
);

# The report can take a while: it reads the catalog and asks clamd.
const my $REQUEST_SECONDS => 30;

# The header the service reads the metrics token from
# (GPForum::Web::OperationsAccess, a layer above this one).
const my $TOKEN_HEADER => 'X-GPForum-Metrics-Token';

# The line above a report, by its status.
const my %HEADING => (
    ok       => 'status.heading_ok',
    degraded => 'status.heading_degraded',
    fail     => 'status.heading_fail',
);

has host    => sub { return GPForum::Service::Operations::Host->new; };
has catalog => sub ($self) { return $self->host->catalog; };

has probe => sub {
    return GPForum::Service::Operations::HttpProbe->new(
        timeout => $REQUEST_SECONDS );
};

# The address the service answers on, from the configuration: the first
# place Hypnotoad listens in staging and production, the development
# server's otherwise. An address on every interface is asked on the
# loopback.
sub address ( $class, $config ) {
    return $DEVELOPMENT_LISTEN if !$config->requires_secure_transport;

    my ($listen) = @{ $config->runtime_listen_locations };
    return $DEVELOPMENT_LISTEN if !defined $listen;

    my $url  = Mojo::URL->new($listen);
    my $host = $url->host // q{};
    if ( exists $LOOPBACK{$host} ) {
        $host = $LOOPBACK{$host};
    }

    return Mojo::URL->new->scheme( $url->scheme )
      ->host($host)
      ->port( $url->port )
      ->to_string;
}

# Asks the service for its readiness report with the metrics token given.
# Returns { state, url, report, code, error }: state is answered (the full
# report), held_back (the status alone: the token was not taken),
# unreachable, or foreign (an answer that is no readiness report).
sub fetch ( $self, $address, $token = undef ) {
    my %headers;
    if ( defined $token && length $token ) {
        $headers{$TOKEN_HEADER} = $token;
    }

    my $answer =
      $self->probe->get( ( $address =~ s{/+\z}{}rmsx ) . '/health/ready',
        \%headers );
    my %result = ( url => $address );
    if ( defined $answer->{error} ) {
        return {
            %result,
            state  => 'unreachable',
            error  => $answer->{error},
            reason => $self->probe->reason( $answer, $self->catalog ),
        };
    }

    $result{code} = $answer->{code};
    my $body = _decoded( $answer->{body} );
    if ( ref $body ne 'HASH' || !defined $body->{status} ) {
        return { %result, state => 'foreign' };
    }
    if ( ref $body->{checks} ne 'ARRAY' ) {
        return { %result, state => 'held_back', report => $body };
    }

    return { %result, state => 'answered', report => $body };
}

# What a fetch found, as an operator reads it: a heading line and the
# findings under it. Returns { heading, findings }.
sub findings ( $self, $result, %context ) {
    my $findings =
      GPForum::Service::Operations::Findings->new( catalog => $self->catalog );
    my $state = $result->{state};
    my $url   = $result->{url};

    if ( $state eq 'answered' ) {
        my $report = $result->{report};
        GPForum::Service::Operations::ReadinessFindings->new(
            catalog        => $self->catalog,
            command_prefix =>
              GPForum::Service::Operations::ReadinessFindings
              ->service_user_prefix(
                $self->host
              ),
        )->findings( $report, findings => $findings );
        my $overall = $report->{status} // 'fail';
        if ( $overall ne 'ok' && $overall ne 'degraded' ) {
            $overall = 'fail';
        }
        return {
            findings => $findings,
            heading  => $self->catalog->text(
                $HEADING{$overall},
                {
                    url         => $url,
                    environment => $report->{environment} // q{?},
                    count       => scalar @{ $report->{checks} },
                }
            ),
        };
    }

    if ( $state eq 'unreachable' ) {
        $findings->add(
            name    => 'service',
            status  => 'fail',
            message => [
                'status.unreachable',
                { url => $url, reason => $result->{reason} // q{} }
            ],
            fixes => [
                $self->host->is_deployed
                ? ( $self->host->start_command('gpforum')
                      // 'gpforum start --foreground' )
                : 'gpforum start --foreground',
                ['status.fix_url'],
            ],
        );
    }
    elsif ( $state eq 'held_back' ) {
        $findings->add(
            name   => 'service',
            status => $result->{report}{status} eq 'fail' ? 'fail' : 'degraded',
            message => [
                'status.held_back',
                { url => $url, state => $result->{report}{status} }
            ],
            fixes => [
                [
                    'status.fix_token',
                    {
                        where   => $context{where} // $self->host->where,
                        restart => $self->_restart( $context{restart} ),
                    }
                ]
            ],
        );
    }
    else {
        $findings->add(
            name    => 'service',
            status  => 'fail',
            message =>
              [ 'status.foreign', { url => $url, code => $result->{code} } ],
            fixes => [ ['status.fix_url'] ],
        );
    }

    return { findings => $findings, heading => undef };
}

# The restart that makes the service read its settings again: the one the
# caller names, else this host's; in development, the forum started again in
# its terminal.
sub _restart ( $self, $given ) {
    return 'gpforum start --foreground' if !$self->host->is_deployed;

    return $given // $self->host->restart_command('gpforum')
      // 'gpforum start --foreground';
}

sub _decoded ($body) {
    my $decoded;
    try {
        $decoded = JSON::MaybeXS->new( utf8 => 1 )->decode( $body // q{} );
    }
    catch ($error) {
        $decoded = undef;
    };

    return $decoded;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::StatusReport - The running service's
readiness report, read with the metrics token, as an operator reads it.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $status  = GPForum::Service::Operations::StatusReport->new;
    my $address = $status->address($config);    # http://127.0.0.1:8080
    my $result  = $status->fetch( $address, $config->metrics_token );
    my $shown   = $status->findings($result);
    say $shown->{heading} if defined $shown->{heading};
    print $shown->{findings}->human_text;

=head1 DESCRIPTION

What C<gpforum status> asks: the full C</health/ready> report of the
service running on this host, with the metrics token from the settings the
front door read, so the operator needs neither curl, the token nor jq. Each
check is a finding (L<GPForum::Service::Operations::ReadinessFindings>);
a service that does not answer, or that keeps its report back because it
does not take the token, is one finding saying what to do.

=head1 SUBROUTINES/METHODS

=head2 host

The L<GPForum::Service::Operations::Host> the commands are written for.

=head2 catalog

The catalog the words come from.

=head2 probe

The L<GPForum::Service::Operations::HttpProbe> the service is asked with.

=head2 address

Class method. The address the service answers on, from a configuration.

=head2 fetch

Takes an address and a token and returns C<state> (C<answered>,
C<held_back>, C<unreachable> or C<foreign>), C<url>, and C<report>, C<code>
or C<error> as they apply.

=head2 findings

Takes what L</fetch> returned and optionally C<where> and C<restart>, the
phrases a fix names, and returns C<heading> (a line for a report, else
undef) and C<findings>.

=head1 DIAGNOSTICS

None: a service that does not answer is a finding.

=head1 CONFIGURATION AND ENVIRONMENT

None of its own.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::HttpProbe>,
L<GPForum::Service::Operations::ReadinessFindings>,
and the C<X-GPForum-Metrics-Token> header L<GPForum::Web::OperationsAccess>
reads.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A UNIX socket address (C<http+unix://>) is asked as Mojo::UserAgent asks
one, which needs the service's group to read the socket; an https address
needs curl or IO::Socket::SSL (L<GPForum::Service::Operations::HttpProbe>).

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
