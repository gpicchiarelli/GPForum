# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::CLI::FrontDoor::Help;
use GPForum::CLI::FrontDoor::Launcher;
use GPForum::Command::Support::Verbs;
use GPForum::Command::Support::Words;
use GPForum::Service::I18N::CliCatalog;

our $VERSION = '0.001';

# gpforum doctor and gpforum status are where the front door's help says
# they are, in Check; and the operator finds them from the documents they
# read: the README, the deployment guide, the index, and the upgrade that
# is three commands ending with gpforum doctor --upgrade (audit item C4).

const my $MOST_COMMANDS => 3;

subtest 'the verbs, in the Check group of the help' => sub {
    for my $verb (qw(doctor status)) {
        my $listed = GPForum::Command::Support::Verbs->find($verb);
        is( $listed->{group}, 'check', "$verb is a Check verb" );
        is( GPForum::CLI::FrontDoor::Launcher->new->resolve($verb)->{class},
            "GPForum::CLI::$verb", 'and runs its command' );
    }
    my $help = GPForum::CLI::FrontDoor::Help->new(
        words => GPForum::Command::Support::Words->new(
            catalog =>
              GPForum::Service::I18N::CliCatalog->new( language => 'en' )
        )
    )->render;
    my ($check) = $help =~ /^Check\n (.*?) \n\n/msx;
    for my $line (
        [ doctor => 'Check the forum, from its settings to its address' ],
        [ status => q{Show the running forum's readiness report} ],
      )
    {
        my ( $verb, $words ) = @{$line};
        like(
            $check,
            qr/^ [ ][ ]\Q$verb\E [ ]+ \Q$words\E/msx,
            "$verb, with its line"
        );
    }
};

subtest 'the upgrade is three commands, the last gpforum doctor --upgrade' =>
  sub {
    my ($block)  = path('docs/ops/upgrade.md')->slurp =~ /```sh\n (.*?) ```/msx;
    my @commands = grep { /\S/msx } split /\n/msx, $block // q{};
    cmp_ok( scalar @commands, '<=', $MOST_COMMANDS, 'at most three' );
    like(
        $commands[-1],
        qr/gpforum [ ] doctor [ ] --upgrade \z/msx,
        'ending with the check'
    );
  };

subtest 'the documents an operator reads point at them' => sub {
    like( path('README.md')->slurp, qr{docs/ops/doctor[.]md}msx, 'the README' );
    my $deployment = path('docs/DEPLOYMENT.md')->slurp;
    like( $deployment, qr{ops/doctor[.]md}msx, 'the deployment guide, doctor' );
    like( $deployment, qr{ops/upgrade[.]md}msx, 'and the upgrade' );
    my $index = path('docs/README.md')->slurp;
    like( $index, qr{ops/doctor[.]md}msx,  'the index, doctor' );
    like( $index, qr{ops/upgrade[.]md}msx, 'and the upgrade' );
};

subtest 'doctor.md explains every line doctor writes' => sub {
    my $guide = path('docs/ops/doctor.md')->slurp;
    for my $line (
        qw(settings host database schema),
        'query budgets',
        'readiness',
        'outbox worker',
        qw(mail antivirus services timer address)
      )
    {
        like( $guide, qr/^ [|] [ ] `\Q$line\E`/msx, "$line has a row" );
    }
};

done_testing();

1;
