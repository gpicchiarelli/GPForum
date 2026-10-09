# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Status;
use GPForum::Config;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ReadinessFindings;
use GPForum::Service::Operations::Readiness;
use GPForum::Service::Operations::StatusReport;
use GPForum::Test::CannedHttpProbe;

our $VERSION = '0.001';

# gpforum status (audit item B4): the running service's whole /health/ready
# report, asked with the metrics token from the settings, written one line
# per check -- no curl, no token typed, no jq. The service is a double that
# answers what /health/ready would.

const my $TOKEN  => 'metrics-token';
const my $SECRET => '0123456789abcdef0123456789abcdef0123456789abcdef';
const my %REPORT => (
    status      => 'degraded',
    environment => 'production',
    checks      => [
        { name => 'database', status => 'ok' },
        {
            name    => 'query_budget_drift',
            status  => 'fail',
            runbook => 'docs/PERFORMANCE.md#query-budgets',
            report  =>
              { missing => ['forum_index'], extra => [], mismatched => [] },
        },
        {
            name    => 'antivirus',
            status  => 'degraded',
            error   => 'cannot connect to clamd',
            runbook => 'docs/ops/antivirus.md',
        },
        { name => 'shared_cache', status => 'ok', mode => 'disabled' },
    ],
);

subtest 'the report, read with the token, one line per check' => sub {
    my $probe = _probe( { code => 200, body => encode_json( \%REPORT ) } );
    my $run   = _run( _command( $probe, 'production' ) );
    is(
        $probe->requests->[0]{url},
        'http://127.0.0.1:8080/health/ready',
        'it asks where Hypnotoad listens, not the proxy'
    );
    is( $probe->requests->[0]{headers}{'X-GPForum-Metrics-Token'},
        $TOKEN, 'with the metrics token from the settings' );
    is( $run->{status}, 1, 'a failed check fails the command' );
    is(
        $run->{output},
        join( "\n",
'http://127.0.0.1:8080: ready, with warnings (production, 4 checks)',
            q{},
            "\N{CHECK MARK} database",
            "\N{CHECK MARK} shared cache: one per process, no GlifiStore",
            "\N{BALLOT X} query budgets: forum_index",
            '    Fix: sudo -u gpforum gpforum budgets --sync',
            '! antivirus: cannot connect to clamd',
            '    Fix: sudo -u gpforum gpforum antivirus-check says why',
            q{},
            '2 things to fix.' )
          . "\n",
        'the heading, each check, the fixes and the count'
    );
};

subtest 'a service keeping its report back says which token to fix' => sub {
    my $probe = _probe(
        {
            code => 200,
            body => encode_json( { status => 'ok', check => 'ready' } )
        }
    );
    my $run = _run( _command( $probe, 'production' ) );
    is( $run->{status}, 0, 'the service is ready: that is not a failure' );
    like(
        $run->{output},
        qr/answers [ ] ok, [ ] but [ ] keeps [ ] the [ ] rest/msx,
        'it says the report was kept back'
    );
    like(
        $run->{output},
        qr/another [ ] GPFORUM_METRICS_TOKEN/msx,
        'and names the token'
    );
};

subtest 'a service that does not answer' => sub {
    my $probe = _probe( { error => 'Connection refused', kind => 'refused' } );
    my $run   = _run( _command( $probe, 'development' ) );
    is( $run->{status}, 1, 'fails' );
    ok(
        index( $run->{output},
                "\N{BALLOT X} http://127.0.0.1:3000 does not answer:"
              . ' connection refused' ) >= 0,
        'in development it asks the forum gpforum start runs'
    );
    like(
        $run->{output},
        qr/Fix: [ ] gpforum [ ] start [ ] --foreground/msx,
        'and says how to start it'
    );
};

subtest 'an answer that is not a readiness report' => sub {
    my $run = _run(
        _command(
            _probe( { code => 404, body => 'Not Found' } ), 'production'
        )
    );
    is( $run->{status}, 1, 'fails' );
    like(
        $run->{output},
        qr/answered [ ] HTTP [ ] 404/msx,
        'saying what came back'
    );
    like(
        $run->{output},
        qr/gpforum [ ] status [ ] --url/msx,
        'and how to name the address'
    );
};

subtest '--json is the report whole, with the lines' => sub {
    my $probe    = _probe( { code => 200, body => encode_json( \%REPORT ) } );
    my $run      = _run( _command( $probe, 'production' ), '--json' );
    my $document = decode_json( $run->{output} );
    is( $document->{command}, 'gpforum-status', 'the command' );
    is( $document->{status},  'degraded',       'the report status' );
    is( $document->{state},   'answered',       'the state of the answer' );
    is_deeply( $document->{report}, \%REPORT,
        'the report as the service gave it' );
    is(
        scalar @{ $document->{findings} },
        scalar @{ $REPORT{checks} },
        'and a finding per check'
    );
};

subtest 'in Italian' => sub {
    my $probe = _probe( { code => 200, body => encode_json( \%REPORT ) } );
    my $run   = _run( _command( $probe, 'production', 'it' ) );
    like( $run->{output}, qr/\A http:\S+ [ ] pronto, [ ] con [ ] avvisi/msx,
        'the heading' );
    like( $run->{output}, qr/budget [ ] delle [ ] query: [ ] forum_index/msx,
        'a check' );
    like( $run->{output}, qr/Rimedio:/msx, 'a fix' );
};

subtest 'the address the service answers on' => sub {
    for my $case (
        [ 'http://*:8080',               'http://127.0.0.1:8080' ],
        [ 'http://0.0.0.0:8080?reuse=1', 'http://127.0.0.1:8080' ],
        [ 'http://[::]:8080',            'http://[::1]:8080' ],
        [
            'http+unix://%2Frun%2Fgpforum%2Fgpforum.sock',
            'http+unix://%2Frun%2Fgpforum%2Fgpforum.sock'
        ],
      )
    {
        my ( $listen, $address ) = @{$case};
        is(
            GPForum::Service::Operations::StatusReport->address(
                _config( 'production', GPFORUM_RUNTIME_LISTEN => $listen )
            ),
            $address,
            "$listen is asked at $address"
        );
    }
};

subtest 'every check readiness makes has a name an operator reads' => sub {
    my $italian = GPForum::Service::Operations::ReadinessFindings->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'it' )
    );
    my %same = map { $_ => 1 } qw(antivirus database runtime);
    my @unnamed =
      grep { !$same{$_} && $italian->label($_) eq tr/_/ /r }
      sort keys %{ GPForum::Service::Operations::Readiness->runbooks };
    is_deeply( \@unnamed, [], 'none is shown under its internal name' );
};

done_testing();

sub _probe ($answer) {
    return GPForum::Test::CannedHttpProbe->new( answer => $answer );
}

sub _config ( $environment, %settings ) {
    return GPForum::Config->from_environment(
        {
            GPFORUM_ENV             => $environment,
            GPFORUM_MAIL_FROM       => 'forum@forum.gpforum.net',
            GPFORUM_METRICS_TOKEN   => $TOKEN,
            GPFORUM_PUBLIC_BASE_URL => $environment eq 'development'
            ? 'http://127.0.0.1:3000'
            : 'https://forum.gpforum.net',
            GPFORUM_SESSION_SECRET => $SECRET,
            %settings,
        }
    );
}

sub _command ( $probe, $environment, $language = 'en' ) {
    my $catalog =
      GPForum::Service::I18N::CliCatalog->new( language => $language );

    return GPForum::Command::Status->new(
        config => _config($environment),
        report => GPForum::Service::Operations::StatusReport->new(
            host => GPForum::Service::Operations::Host->new(
                catalog     => $catalog,
                environment => $environment,
                os          => GPForum::OS->from_name('linux'),
            ),
            probe => $probe,
        ),
    );
}

sub _run ( $command, @arguments ) {
    my $output = q{};
    open my $handle, '>', \$output or croak "cannot capture: $OS_ERROR";
    my $status;
    {
        local *STDOUT = $handle;
        $status = $command->run(@arguments);
    }
    close $handle or croak "cannot capture: $OS_ERROR";
    utf8::decode($output);

    return { status => $status, output => $output };
}

1;
