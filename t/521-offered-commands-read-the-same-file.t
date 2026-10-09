# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Command::Migrate;
use GPForum::Command::Secret;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Test::AppliedRunner;
use GPForum::Test::BudgetSync;
use GPForum::Test::WindowLifecycle;

our $VERSION = '0.001';

const my $SECRET_FILE_MODE => oct '640';

# What the generator appends, so a secret it makes is as long as production
# asks of one.
const my $LONG => 'x' x 32;

# A command the front door ran with --env-file FILE offers the next one with
# --env-file FILE too: `gpforum secret rotate session --finish`, typed as
# offered a month later, finished the host's file instead, and `gpforum
# admin create`, after `gpforum --env-file FILE migrate`, made the owner of
# the database the host's file names.

local $ENV{LC_ALL} = 'en_US.UTF-8';
my $directory = tempdir( CLEANUP => 1 );
my $file      = path( $directory, 'staging.env' );
$file->spew( path('deploy/gpforum.env.example')->slurp );
chmod $SECRET_FILE_MODE, "$file" or croak "chmod: $ERRNO";

GPForum::Command::Support::ServiceEnvironment->new(
    file        => "$file",
    environment => {},
)->load;

subtest 'secret rotate offers --finish for the file it wrote' => sub {
    my $counter = 0;
    my $secret  = GPForum::Command::Secret->new(
        generate => sub { return 'new-' . ++$counter . $LONG } );
    _captured( sub { return $secret->run(qw(rotate session)) } );
    my $run = _captured( sub { return $secret->run(qw(rotate session)) } );
    my ($then) = $run->{output} =~ /^Then: [ ] ([^\n]*)/msx;
    like(
        $then // q{},
        qr/gpforum [ ] --env-file [ ] \Q$file\E [ ] secret [ ] rotate/msx,
        'the step after names the file'
    );
    like( $then // q{}, qr/--finish \z/msx, 'and finishes it' );
};

subtest 'migrate offers admin create against the same database' => sub {
    my $migrate = GPForum::Command::Migrate->new(
        default_mode        => 'apply',
        owner_check         => sub { return 0; },
        partition_lifecycle => GPForum::Test::WindowLifecycle->new,
        query_budget        => GPForum::Test::BudgetSync->new,
        runner => GPForum::Test::AppliedRunner->new( applied => [] ),
    );
    my $run = _captured( sub { return $migrate->run } );
    like(
        $run->{output},
qr/^Next: .* gpforum [ ] --env-file [ ] \Q$file\E [ ] admin [ ] create/msx,
        'the owner is made where the schema was'
    );
};

done_testing();

sub _captured ($code) {
    my ( $output, $errors ) = ( q{}, q{} );
    my $status;
    {
        open my $stdout, '>', \$output or croak 'capture stdout';
        open my $stderr, '>', \$errors or croak 'capture stderr';
        local *STDOUT = $stdout;
        local *STDERR = $stderr;
        $status = $code->();
        close $stdout or croak 'close stdout';
        close $stderr or croak 'close stderr';
    }

    return { errors => $errors, output => $output, status => $status };
}

1;
