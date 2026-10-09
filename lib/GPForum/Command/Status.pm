# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Status;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Verbs;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::StatusReport;

our $VERSION = '0.001';

const my $COMMAND => 'gpforum-status';

# An address the service may be asked at instead of the configured one.
const my $ADDRESS => qr{\A (?: https? | http[+]unix ) :// \S+ \z}msx;

has report => sub { return GPForum::Service::Operations::StatusReport->new; };
has config => undef;    # optional: read from the environment otherwise
has service_environment =>
  sub { return GPForum::Command::Support::ServiceEnvironment->new; };

# `gpforum status [--url URL] [--json]`: the running service's full
# readiness report, read with the metrics token from the settings, in
# sentences. The work is GPForum::Service::Operations::StatusReport's.
sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $options;
    try {
        $options = GPForum::Command::Usage->parse_options(
            \@arguments,
            {},
            {
                switches => { '--json' => { json => 1 } },
                values   => {
                    '--url' => sub ( $options, $value ) {
                        $options->{url} =
                          GPForum::Command::Usage->option_value( $value,
                            $ADDRESS, _usage(), '--url' );
                    },
                },
                usage => _usage(),
            }
        );
    }
    catch ($error) {
        return GPForum::Command::Usage->error(
            GPForum::Command::Usage->trimmed($error), _usage() )
          if GPForum::Command::Usage->is_usage($error);
        die $error;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
    };

    my $result;
    try {
        my $config = $self->config // GPForum::Config->from_environment;
        $result =
          $self->report->fetch( $options->{url}
              // $self->report->address($config),
            $config->metrics_token );
    }
    catch ($error) {
        return GPForum::Command::Usage->failure( $error,
            $options->{json}
            ? ( \*STDOUT, { command => $COMMAND, report => undef } )
            : () );
    };

    my $shown = $self->report->findings(
        $result,
        restart => $self->service_environment->restart_command,
        where   => $self->_where,
    );
    my $findings = $shown->{findings};
    if ( $options->{json} ) {
        GPForum::Command::Usage->json(
            \*STDOUT,
            {
                command  => $COMMAND,
                state    => $result->{state},
                url      => $result->{url},
                report   => $result->{report},
                findings => $self->service_environment->findings_as_read(
                    $findings->document
                ),
                status => $result->{state} eq 'answered'
                ? $result->{report}{status}
                : $findings->status,
            }
        );
        return $findings->exit_status;
    }

    my $text = $findings->human_text( summary => 1 );
    if ( defined $shown->{heading} ) {
        $text = "$shown->{heading}\n\n$text";
    }
    print encode(
        'UTF-8',
        $self->service_environment->as_read(
            GPForum::Command::Support::Verbs->as_typed($text)
        )
    ) or croak 'failed to write the status report';

    return $findings->exit_status;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints.
sub usage_text ($class) {
    return _usage();
}

# Where the metrics token is changed: the file the front door read, else
# undef for the host's own phrase.
sub _where ($self) {
    my $file = GPForum::Command::Support::ServiceEnvironment->loaded;
    return undef if !defined $file;

    return GPForum::Service::I18N::CliCatalog->new->text( 'database.where_file',
        { path => $file } );
}

sub _usage {
    return <<'USAGE';
Usage: gpforum status [--url URL] [--json]

Shows the running forum's readiness report -- every check /health/ready
makes, each with what it found and, when it is not ok, the command that
says more -- read with the metrics token from the settings, so no curl,
token or jq is needed.

  --url URL   ask the service at this address (default: where it listens,
              GPFORUM_RUNTIME_LISTEN, or http://127.0.0.1:3000 in
              development)
  --json      one JSON object on stdout: the state, and the report whole
  --help      show this help

Exit status: 0 the forum is ready (warnings are listed), 1 it is not, or it
does not answer, 2 usage error.
USAGE
}

1;

__END__

=head1 NAME

GPForum::Command::Status - C<gpforum status>: the running forum's readiness
report, in sentences.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # gpforum status
    # gpforum status --url http://127.0.0.1:8080 --json
    exit GPForum::Command::Status->new->run(@ARGV);

=head1 DESCRIPTION

Asks the service running on this host for its full C</health/ready> report,
with the metrics token the settings hold, and prints a line saying whether
it is ready, then each check as a finding
(L<GPForum::Service::Operations::StatusReport>). A service that does not
answer, or keeps its report back because it does not take the token, is
said with what to do.

=head1 SUBROUTINES/METHODS

=head2 report

The L<GPForum::Service::Operations::StatusReport> that does the work.

=head2 config

The configuration; read from the environment when not given.

=head2 service_environment

The L<GPForum::Command::Support::ServiceEnvironment> whose restart command a
fix names.

=head2 run

Runs the command line. Returns 0 when the forum is ready, 1 when it is not
or does not answer, and 2 on misuse; settings it cannot use exit 78.

=head2 usage_text

The text C<--help> prints.

=head1 DIAGNOSTICS

Settings that do not parse are reported as every command reports them.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_METRICS_TOKEN> and C<GPFORUM_RUNTIME_LISTEN>, from the
environment file the front door read.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::StatusReport>, L<GPForum::Config>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The C<--help> text is English.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
