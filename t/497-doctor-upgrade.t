# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use File::Temp    qw(tempdir);
use JSON::MaybeXS qw(decode_json);
use Mojo::File    qw(path);
use Test::More;

use lib 'lib';

use GPForum::Command::Doctor;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Dependencies;
use GPForum::Service::Operations::Doctor;

our $VERSION = '0.001';

# The test cpanfile's run-time requirements, perl left out.
const my $RUNTIME_REQUIREMENTS => 4;

# gpforum doctor --upgrade (audit item C4), the last of the upgrade's three
# commands: the modules this release needs, for the Perl running it; the
# migrations still to apply; the service files and running services an
# upgrade leaves behind -- and not the mail, antivirus and address checks of
# a plain gpforum doctor. And the command around both: its exit status, its
# closing count, the line that says the rest waits for the settings, and
# --json.

subtest 'the modules a release needs, for this Perl' => sub {
    my $root = tempdir( CLEANUP => 1 );
    path( $root, 'cpanfile' )->spew(<<'CPANFILE');
requires 'perl', '5.040';
requires 'Mojolicious', '9.0';
requires 'Not::Installed::Anywhere';
requires 'Test::More', '999';
requires 'DBD::Pg';
on test => sub {
    requires 'Only::For::Tests';
};
CPANFILE
    my $dependencies = GPForum::Service::Operations::Dependencies->new(
        root   => $root,
        loader => sub ($module) {
            return $module eq 'DBD::Pg'
              ? "DBD::Pg object version 3.18 does not match bootstrap parameter 3.21\n"
              : undef;
        },
    );
    is_deeply(
        [ map { $_->{module} } @{ $dependencies->requirements } ],
        [qw(perl Mojolicious Not::Installed::Anywhere Test::More DBD::Pg)],
        q{the run-time requirements, not the test phase's}
    );

    my $result = $dependencies->check;
    is( $result->{status}, 'fail', 'something is wrong' );
    is_deeply(
        [ map { $_->{module} } @{ $result->{missing} } ],
        ['Not::Installed::Anywhere'],
        'a module not installed'
    );
    is_deeply( [ map { $_->{module} } @{ $result->{outdated} } ],
        ['Test::More'], 'one older than the release needs' );
    is_deeply( [ map { $_->{module} } @{ $result->{broken} } ],
        ['DBD::Pg'], 'and one built for another Perl' );
    is( $result->{count}, $RUNTIME_REQUIREMENTS,
        'counted without perl itself' );
};

subtest '--upgrade checks what an upgrade leaves behind' => sub {
    my %asked;
    my $doctor = _doctor(
        \%asked,
        upgrade => 1,
        probes  => {
            dependencies => sub {
                return {
                    status   => 'fail',
                    perl     => '5.44.0',
                    count    => 18,
                    missing  => [],
                    outdated =>
                      [ { module => 'Mojolicious', wanted => '9.42' } ],
                    broken => [],
                };
            },
            schema => sub {
                return {
                    latest  => '052',
                    pending => [ { version => '052', description => 'new' } ],
                };
            },
        },
    );
    my $text = $doctor->check->{findings}->human_text;
    _has(
        $text,
        'dependencies: older than this release needs: Mojolicious',
        'the modules to install again'
    );
    _has( $text, 'Fix: make install-deps-postgres', 'with the make target' );
    _has(
        $text,
        'schema: 1 migration to apply, 052 new',
        'the migration still to apply'
    );
    is_deeply(
        [ sort keys %asked ],
        [qw(database dependencies schema)],
'and not mail, the antivirus, the outbox, the readiness report or the address'
    );
};

subtest 'the command: count, exit status, and the settings first' => sub {
    my $healthy =
      _run( GPForum::Command::Doctor->new( doctor => _doctor( {} ) ) );
    is( $healthy->{status}, 0, 'nothing failed: 0' );
    like(
        $healthy->{output},
        qr/\n\nNothing [ ] to [ ] fix[.]\n\z/msx,
        'ending with the count'
    );

    my $waiting = _run(
        GPForum::Command::Doctor->new(
            doctor => _doctor( {}, environment => { GPFORUM_ENV => 'prod' } )
        )
    );
    is( $waiting->{status}, 1, 'settings it cannot use fail it' );
    _has(
        $waiting->{output},
        "are checked once the settings above are right.\n\n1 thing to fix.\n",
        'and it says the rest waits for them'
    );

    my $json = _run(
        GPForum::Command::Doctor->new(
            doctor => _doctor( {}, environment => { GPFORUM_ENV => 'prod' } )
        ),
        '--json'
    );
    my $document = decode_json( $json->{output} );
    is( $document->{command},  'gpforum-doctor', 'the JSON names the command' );
    is( $document->{status},   'fail',           'its status' );
    is( $document->{problems}, 1,                'the count' );
    is( $document->{waiting},  1,                'that the rest waits' );
    is( $document->{findings}[0]{name}, 'settings', 'and each finding' );

    my $misuse = _run( GPForum::Command::Doctor->new, '--bogus' );
    is( $misuse->{status}, 2, 'an option it does not know is misuse' );
};

done_testing();

# A development doctor on doubles; %asked records which probes ran.
sub _doctor ( $asked, %options ) {
    my %probes = (
        address   => sub { return { code   => 200 } },
        antivirus => sub { return { status => 'disabled', engine => 'none' } },
        budgets   =>
          sub { return { missing => [], extra => [], mismatched => [] } },
        database     => sub { return { schema => {}, version => '18.6' } },
        dependencies => sub {
            return { status => 'ok', count => 18, perl => '5.44.0' };
        },
        mail => sub {
            return { status => 'pass', probe => { action => 'log_transport' } };
        },
        outbox    => sub { return { waiting => 0 } },
        preflight => sub { return { checks  => [] } },
        readiness => sub { return { status  => 'ok',  checks  => [] } },
        schema    => sub { return { latest  => '051', pending => [] } },
        %{ delete $options{probes} // {} },
    );
    my %recorded =
      map { $_ => _recorded( $asked, $_, $probes{$_} ) } keys %probes;

    return GPForum::Service::Operations::Doctor->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'en' ),
        environment => { GPFORUM_ENV => 'development' },
        file        => undef,
        probes      => \%recorded,
        %options,
    );
}

# A probe that notes, by name, that it ran.
sub _recorded ( $asked, $name, $probe ) {
    return sub (@arguments) {
        $asked->{$name} = 1;
        return $probe->(@arguments);
    };
}

sub _has ( $text, $phrase, $name ) {
    ok( index( $text, $phrase ) >= 0, $name ) or diag $text;

    return;
}

sub _run ( $command, @arguments ) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    {
        open my $out, '>', \$output or croak "cannot capture: $OS_ERROR";
        open my $err, '>', \$errors or croak "cannot capture: $OS_ERROR";
        local *STDOUT = $out;
        local *STDERR = $err;
        $status = $command->run(@arguments);
        close $out or croak "cannot capture: $OS_ERROR";
        close $err or croak "cannot capture: $OS_ERROR";
    }
    utf8::decode($output);

    return { status => $status, output => $output, errors => $errors };
}

1;
