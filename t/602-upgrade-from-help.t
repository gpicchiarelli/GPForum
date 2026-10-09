# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;
use utf8;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json);
use Mojo::File    qw(path);
use Test::More;

use lib 'lib';

use GPForum::CLI::FrontDoor::Help;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Upgrade;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Dependencies;
use GPForum::Service::Operations::Host;

our $VERSION = '0.001';

# Walkthrough 3, friction 5: gpforum help never said "upgrade", and the
# three commands were in docs/ops/upgrade.md alone, reached through gpforum
# help doctor's last line. upgrade.md also said gpforum migrate names the
# restart; with nothing to apply it named none. gpforum upgrade is now in
# the help, under Maintain, and prints the same three lines upgrade.md
# gives, with the restart on the second whatever the migration finds.

const my $EXIT_USAGE => 2;
const my $CODE       => '/opt/gpforum';
const my $STEPS      => 3;

# The title, a blank line, then the three steps.
const my $LAST_STEP_LINE => 4;

subtest 'gpforum help lists it, under Maintain' => sub {
    my $help = GPForum::CLI::FrontDoor::Help->new(
        words       => _words('en'),
        environment =>
          GPForum::Command::Support::ServiceEnvironment->new( file => undef ),
    )->render;
    my ($maintain) = $help =~ /^Maintain\n (.*?) \n\n/msx;
    like(
        $maintain // q{},
qr/^ [ ][ ]upgrade [ ]+ Print [ ] the [ ] commands [ ] that [ ] upgrade/msx,
        'upgrade, with its line'
    );
};

subtest 'a Debian host: the three lines upgrade.md gives' => sub {
    my ($block)  = path('docs/ops/upgrade.md')->slurp =~ /```sh\n (.*?) ```/msx;
    my @document = grep { /\S/msx } split /\n/msx, $block // q{};
    my $plan     = _upgrade( 'linux', 'production' )->plan;
    is_deeply( $plan->{steps}, \@document,
        'gpforum upgrade and upgrade.md say the same' );
    like(
        $plan->{steps}[1],
        qr/gpforum [ ] migrate [ ] && [ ] sudo [ ] systemctl [ ] restart/msx,
        'the restart follows the migration, whatever it applies'
    );
    is(
        $plan->{backup},
        'sudo -u gpforum gpforum backup --to /var/backups/gpforum',
        'and the backup to take first is upgrade.md\'s'
    );
    like( path('docs/ops/upgrade.md')->slurp,
        qr/\Q$plan->{backup}\E/msx, 'which it names' );
};

subtest 'each host its own restart' => sub {
    like(
        _upgrade( 'freebsd', 'production' )->plan->{steps}[1],
        qr/&& [ ] sudo [ ] service [ ] gpforum [ ] restart/msx,
        'rc.d on FreeBSD'
    );
    like(
        _upgrade( 'darwin', 'production' )->plan->{steps}[1],
        qr/&& [ ] sudo [ ] launchctl [ ] kickstart/msx,
        'launchd on macOS'
    );
};

subtest 'a development checkout' => sub {
    my $output = _run( _upgrade( 'linux', 'development' ) );
    is( $output->{status}, 0, 'exit 0' );
    my @lines = split /\n/msx, $output->{stdout};
    is_deeply(
        [ @lines[ 0 .. $LAST_STEP_LINE ] ],
        [
            'Upgrade this forum with these three commands, in order:',
            q{},
            "  cd $CODE && git pull && make install-deps-postgres",
            '  gpforum migrate',
            '  gpforum doctor --upgrade',
        ],
        'from the checkout, as its owner'
    );
    like(
        $output->{stdout},
        qr/^After [ ] gpforum [ ] migrate, [ ] restart [ ] the [ ] forum/msx,
        'and the forum run by hand restarted after the migration'
    );
    unlike( $output->{stdout}, qr/backup/msx, 'no backup asked of it' );
};

subtest 'in Italian' => sub {
    my $output = _run( _upgrade( 'linux', 'production', 'it' ) );
    like(
        $output->{stdout},
qr/\A Aggiorna [ ] questo [ ] forum [ ] con [ ] questi [ ] tre [ ] comandi/msx,
        'the title'
    );
    like(
        $output->{stdout},
        qr/Niente [ ] da [ ] sistemare/msx,
        q{and doctor's last line, as doctor writes it}
    );
};

subtest 'its --json and its misuse' => sub {
    my $output   = _run( _upgrade( 'linux', 'production' ), '--json' );
    my $document = decode_json( $output->{stdout} );
    is( $document->{status},            'ok',   'a status' );
    is( scalar @{ $document->{steps} }, $STEPS, 'three steps' );
    is( _run( _upgrade( 'linux', 'production' ), '--aply' )->{status},
        $EXIT_USAGE, 'an option it does not know is misuse' );
};

done_testing();

sub _upgrade ( $os, $environment, $language = 'en' ) {
    my $system = GPForum::OS->from_name($os);

    return GPForum::Command::Upgrade->new(
        host => GPForum::Service::Operations::Host->new(
            os          => $system,
            environment => $environment,
        ),
        service_environment =>
          GPForum::Command::Support::ServiceEnvironment->new( os => $system ),
        dependencies =>
          GPForum::Service::Operations::Dependencies->new( root => $CODE ),
        words => _words($language),
    );
}

sub _words ($language) {
    return GPForum::Command::Support::Words->new( catalog =>
          GPForum::Service::I18N::CliCatalog->new( language => $language ) );
}

sub _run ( $command, @arguments ) {
    my ( $stdout, $stderr ) = ( q{}, q{} );
    my $status;
    {
        open my $out, '>', \$stdout or croak 'capture stdout';
        open my $err, '>', \$stderr or croak 'capture stderr';
        local *STDOUT = $out;
        local *STDERR = $err;
        $status = $command->run(@arguments);
        close $out or croak 'close stdout';
        close $err or croak 'close stderr';
    }
    utf8::decode($stdout);

    return { status => $status, stderr => $stderr, stdout => $stdout };
}

1;
