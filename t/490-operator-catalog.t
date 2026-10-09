# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use File::Find qw(find);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Findings;

our $VERSION = '0.001';

# What the host checks say to an operator -- gpforum doctor and status, the
# OS preflight, the mail and antivirus checks -- is written from the
# command-line catalogs, in Italian or English (owner decision D13). A key
# the code asks for that a catalog lacks would reach the operator as the key
# itself, so each one is looked for in both.

const my @PREFIXES =>
  qw(findings preflight doctor status mailcheck antivirus hostverify setup);
const my $PREFIX => join q{|}, @PREFIXES;
const my $ASKED => qr/' ( (?:$PREFIX) [.] \w+ ) '/msx;

my $catalogs = GPForum::Service::I18N::CliCatalog->catalogs;

my %asked;
find(
    {
        no_chdir => 1,
        wanted   => sub {
            return if !/[.]pm\z/msx;
            my $code = path($_)->slurp;
            $code =~ s/^__END__$ .*//msx;
            for my $key ( $code =~ /$ASKED/gmsx ) {
                $asked{$key} = $_;
            }
        },
    },
    'lib'
);

ok( scalar keys %asked, 'the host checks ask for their words by key' );
for my $language (qw(en it)) {
    is_deeply( [ grep { !exists $catalogs->{$language}{$_} } sort keys %asked ],
        [], "and the $language catalog has every one" );
}

subtest 'a finding reads in the language chosen' => sub {
    for my $case (
        [ en => "\N{CHECK MARK} host: Linux with epoll, 1 CPU" ],
        [ it => "\N{CHECK MARK} host: Linux con epoll, 1 CPU" ],
      )
    {
        my ( $language, $line ) = @{$case};
        my $findings =
          GPForum::Service::Operations::Findings->new( catalog =>
              GPForum::Service::I18N::CliCatalog->new( language => $language )
          );
        $findings->add(
            name    => 'host',
            status  => 'ok',
            message =>
              [ 'preflight.host_one', { os => 'Linux', backend => 'epoll' } ],
        );
        is( ( split /\n/msx, $findings->human_text )[0], $line, $language );
    }
};

subtest 'the marks, the fixes and the count' => sub {
    my $findings = GPForum::Service::Operations::Findings->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'en' )
    );
    $findings->add( name => 'one', status => 'ok', message => 'all well' );
    $findings->add(
        name    => 'two',
        status  => 'degraded',
        message => 'a warning',
        notes   => ['what it proved'],
        fixes   => [ 'do this', 'or that' ],
    );
    $findings->add( name => 'three', status => 'fail', message => 'a failure' );
    $findings->add(
        name    => 'four',
        status  => 'skipped',
        message => 'not looked at'
    );

    is(
        $findings->human_text,
        join( "\n",
            "\N{CHECK MARK} all well",
            '! a warning',
            '    what it proved',
            '    Fix: do this',
            '         or that',
            "\N{BALLOT X} a failure",
            q{},
            '2 things to fix.' )
          . "\n",
        'a mark each, notes and fixes under a problem, skipped left out'
    );
    is( $findings->status,      'fail', 'the worst status is the status' );
    is( $findings->exit_status, 1,      'and a failure exits 1' );
    is_deeply(
        [ map { $_->{status} } @{ $findings->document } ],
        [qw(ok degraded fail skipped)],
        'while --json keeps every finding, the skipped one too'
    );

    my $warned = GPForum::Service::Operations::Findings->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'it' ) )
      ->add( name => 'w', status => 'degraded', message => 'x' );
    is( $warned->exit_status, 0,
        'a warning alone is reported and still exits 0' );
    like(
        $warned->human_text,
        qr/^1 [ ] cosa [ ] da [ ] sistemare[.]$/msx,
        'and counted in the operator language'
    );

    my $refused = 0;
    try {
        $warned->add( name => 'x', status => 'warn', message => 'x' );
    }
    catch ($error) {
        $refused = 1;
    };
    ok( $refused, 'a status it does not know is refused' );
};

done_testing();

1;
