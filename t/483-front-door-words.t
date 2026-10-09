# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use File::Find qw(find);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Command::Support::Verbs;
use GPForum::Command::Support::Words;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::I18N::PoFile;

our $VERSION = '0.001';

# Owner decision D13: what the front door says follows LC_ALL, LC_MESSAGES or
# LANG, Italian or English. Its words are the cli.* entries of
# locale/cli/en.po and it.po; the English is also in
# GPForum::Command::Support::Words, as a msgid is in gettext's sources.

my $english  = GPForum::Command::Support::Words->english;
my $catalogs = GPForum::Service::I18N::CliCatalog->catalogs;

subtest q{the catalogs carry every word, en.po's in the code's English} => sub {
    my %msgid =
      map  { $_->{context} => $_->{id} }
      grep { defined $_->{context} }
      @{ GPForum::Service::I18N::PoFile->read_file('locale/cli/en.po')
          ->{entries} };
    for my $language (qw(en it)) {
        is_deeply(
            [
                grep { !exists $catalogs->{$language}{$_} }
                sort keys %{$english}
            ],
            [],
            "$language.po has every cli.* key"
        );
    }
    is_deeply(
        [
            grep { ( $msgid{$_} // q{} ) ne $english->{$_} }
            sort keys %{$english}
        ],
        [],
        q{en.po's msgid is the code's English}
    );
    is_deeply(
        [ grep { /\A cli[.]/msx && !exists $english->{$_} } sort keys %msgid ],
        [],
        'and en.po has no cli.* key the code dropped'
    );
};

subtest 'every word the code asks for is there' => sub {
    my %asked;
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if !/[.]pm\z/msx;
                my $code = path($_)->slurp;
                $code =~ s/^__END__$ .*//msx;
                my @keys = $code =~ /'(cli[.][\w.]+\w)'/gmsx;
                @asked{@keys} = (1) x @keys;
            },
        },
        'lib'
    );
    ok( scalar keys %asked, 'the code asks for cli.* words' );

    # And the ones it builds from a name.
    for
      my $shape (qw(positive_integer non_negative_integer non_negative_number))
    {
        $asked{"cli.misuse.$shape"} = 1;
    }
    for my $group ( @{ GPForum::Command::Support::Verbs->groups } ) {
        $asked{"cli.help.group.$group"} = 1;
    }
    for my $verb ( @{ GPForum::Command::Support::Verbs->verbs } ) {
        $asked{ 'cli.verb.' . ( $verb->{verb} =~ tr/-/_/r ) } = 1;
    }
    _ask_built( \%asked );

    is_deeply( [ grep { !exists $english->{$_} } sort keys %asked ],
        [], 'each is in the English' );
};

subtest 'the words read in Italian when the language asks for it' => sub {
    my $italian = GPForum::Command::Support::Words->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'it' )
    );
    is(
        $italian->text( 'cli.migrate.current', { version => '051' } ),
        "Lo schema \N{LATIN SMALL LETTER E WITH GRAVE} aggiornato (051)",
        'a sentence, with its value'
    );
    is( $italian->text('cli.help.group.setup'),
        'Installazione', 'a group of the help' );
    like(
        $italian->config_report(
            [
                {
                    key        => 'config.required_in',
                    variable   => 'GPFORUM_METRICS_TOKEN',
                    parameters => { environment => 'production' },
                }
            ],
            '/etc/gpforum/gpforum.env'
        ),
        qr{^Impostale [ ] in [ ] /etc/gpforum/gpforum[.]env, }msx,
        'and a report ends naming the file read'
    );

    my $english_words = GPForum::Command::Support::Words->new(
        catalog => GPForum::Service::I18N::CliCatalog->new( language => 'en' )
    );
    like(
        $english_words->config_report(
            [ { key => 'config.required', variable => 'GPFORUM_ENV' } ]
        ),
        qr{deploy/gpforum[.]env[.]example}msx,
        'without a file read, the report names the template, as before'
    );
};

done_testing();

# The keys the code builds from a secret's kind and an outcome, and from a
# count: _one or _many.
sub _ask_built ($asked) {
    my @outcomes =
      qw(rotated first finished would_rotated would_first would_finished then);
    for my $kind (qw(session metrics)) {
        for my $outcome (@outcomes) {
            $asked->{"cli.secret.$kind.$outcome"} = 1;
        }
    }
    for my $counted (qw(applied partitions pending)) {
        delete $asked->{"cli.migrate.$counted"};
        for my $form (qw(one many)) {
            $asked->{"cli.migrate.${counted}_$form"} = 1;
        }
    }

    return;
}

1;
