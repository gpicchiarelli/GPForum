# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;
use utf8;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Mojo::Util qw(decode);
use Test::More;

use lib 'lib';

use GPForum::Command::Service;
use GPForum::Command::Support::Words;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;

our $VERSION = '0.001';

# The review of gpforum service print --to (audit C2), as an operator used
# it: the steps type it through sudo on a deployed host, so a link under
# one of the files' names is refused and the file it names left alone, a
# file already there is replaced rather than written through, and a
# directory another account can change is refused.

const my $EXIT_OK      => 0;
const my $EXIT_FAILURE => 1;
const my $FILE_MODE    => oct '7777';
const my $OPEN         => oct '777';
const my $EXECUTABLE   => oct '755';
const my $ROOT         => path(q{.})->to_abs->to_string;
const my $VICTIM       => "the operator's own file\n";

subtest 'a link under a file name is refused, and what it names untouched' =>
  sub {
    my $place  = tempdir( CLEANUP => 1 );
    my $victim = path( $place, 'victim' );
    $victim->spew($VICTIM);
    $victim->chmod( oct '600' );
    my $into = path( $place, 'units' )->make_path;
    symlink $victim->to_string, $into->child('gpforum.conf')->to_string
      or croak "symlink: $OS_ERROR";

    for my $language (qw(en it)) {
        my $run = _run( $language, qw(print nginx --to), $into->to_string );
        is( $run->{status}, $EXIT_FAILURE, "refused ($language)" );
        like(
            $run->{errors},
            $language eq 'en'
            ? qr/holds [ ] gpforum[.]conf [ ] as [ ] links/msx
            : qr/contiene [ ] gpforum[.]conf [ ] come [ ] link/msx,
            'saying which name is a link'
        );
    }
    is( $victim->slurp, $VICTIM, 'the file the link names is not written' );
    is( ( stat $victim )[2] & $FILE_MODE, oct '600', 'nor its mode changed' );
  };

subtest 'a file left under its name is replaced, not written through' => sub {
    my $into = path( tempdir( CLEANUP => 1 ), 'units' )->make_path;
    my $old  = $into->child('gpforum');
    $old->spew("old\n");
    my $before = ( stat $old )[1];
    my $kept   = path( tempdir( CLEANUP => 1 ), 'kept' );
    link $old->to_string, $kept->to_string or croak "link: $OS_ERROR";

    my $run = _run( 'en', qw(print rc --to), $into->to_string );
    is( $run->{status}, $EXIT_OK, 'written' ) or diag $run->{errors};
    isnt( ( stat $old )[1], $before, 'as a new file under the name' );
    is( $kept->slurp, "old\n", 'so a hard link to the old one is untouched' );
    is( ( stat $old )[2] & $FILE_MODE,
        $EXECUTABLE, 'and the rc script executable' );
    is_deeply(
        [ sort map { $_->basename } $into->list( { hidden => 1 } )->each ],
        [qw(gpforum gpforum_jobs gpforum_outbox)],
        'with nothing left beside the files'
    );
};

subtest 'a directory another account can change is refused' => sub {
    my $into = path( tempdir( CLEANUP => 1 ), 'shared' )->make_path;
    $into->chmod($OPEN);
    my $run = _run( 'en', qw(print systemd --to), $into->to_string );
    is( $run->{status}, $EXIT_FAILURE, 'refused' );
    like( $run->{errors},
        qr/can [ ] be [ ] changed [ ] by [ ] another [ ] account/msx,
        'saying why' );
    is_deeply( [ $into->list( { hidden => 1 } )->each ],
        [], 'and nothing is written there' );

    my $italian = _run( 'it', qw(print systemd --to), $into->to_string );
    like(
        $italian->{errors},
        qr/può [ ] essere [ ] modificata [ ] da [ ] un [ ] altro/msx,
        'in Italian too'
    );
};

done_testing;

sub _run ( $language, @arguments ) {
    my $catalog =
      GPForum::Service::I18N::CliCatalog->new( language => $language );
    my $command = GPForum::Command::Service->new(
        directory => $ROOT,
        files     => GPForum::Service::Operations::ServiceFiles->new(
            environment => {},
            host        => _host( 'linux', $catalog ),
            home        => '/opt/gpforum',
        ),
        words => GPForum::Command::Support::Words->new( catalog => $catalog ),
    );
    my ( $output, $errors ) = ( q{}, q{} );
    open my $stdout, '>', \$output or croak 'capture stdout';
    open my $stderr, '>', \$errors or croak 'capture stderr';
    $command->output($stdout);
    $command->errors($stderr);
    my $status = $command->run(@arguments);
    close $stdout or croak 'close stdout';
    close $stderr or croak 'close stderr';

    return {
        status => $status,
        output => $output,
        errors => decode( 'UTF-8', $errors ),
    };
}

sub _host ( $os, $catalog ) {
    return GPForum::Service::Operations::Host->new(
        catalog     => $catalog,
        environment => 'production',
        os          => GPForum::OS->from_name($os),
    );
}

1;
