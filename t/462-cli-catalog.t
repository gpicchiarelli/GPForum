# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use File::Find qw(find);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Config::Report;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::I18N::PoFile;

our $VERSION = '0.001';

# What GPForum says to an operator follows LANG, Italian or English, like the
# forum (owner decision D13). The words are locale/cli/en.po and it.po; the
# forum's own catalogs, locale/*.po, are the pages' and stay apart.

const my $CLI_DIRECTORY => 'locale/cli';
const my $PLACEHOLDER   => qr/[{] (\w+) [}]/msx;

my $catalogs = GPForum::Service::I18N::CliCatalog->catalogs;
my %english  = %{ $catalogs->{en} // {} };
my %italian  = %{ $catalogs->{it} // {} };

subtest 'both catalogs carry every key, translated' => sub {
    is_deeply( [ sort keys %{$catalogs} ], [qw(en it)], 'English and Italian' );
    ok( scalar keys %english, 'English has messages' );
    is_deeply(
        [ sort keys %italian ],
        [ sort keys %english ],
        'Italian has exactly the same keys'
    );
    is_deeply( [ grep { !length $italian{$_} } sort keys %italian ],
        [], 'and a translation for each' );
    is_deeply(
        [
            sort grep {
                _placeholders( $english{$_} ) ne _placeholders( $italian{$_} )
              }
              keys %english
        ],
        [],
        'with the same placeholders in both languages'
    );
};

subtest q{the config report's English is the English catalog's} => sub {
    my $source = GPForum::Config::Report->english;
    is_deeply( [ grep { !exists $english{$_} } sort keys %{$source} ],
        [], 'every key GPForum::Config::Report raises is in the catalog' );
    is_deeply( [ grep { $english{$_} ne $source->{$_} } sort keys %{$source} ],
        [], 'in the same words' );

    my %msgid =
      map { $_->{context} => $_->{id} }
      @{ GPForum::Service::I18N::PoFile->read_file("$CLI_DIRECTORY/en.po")
          ->{entries} };
    is_deeply( [ grep { $msgid{$_} ne $english{$_} } sort keys %english ],
        [], q{and en.po's msgid is its English text, as gettext keeps it} );
};

subtest 'every key the code asks for is in the catalogs' => sub {
    my %asked;
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return if !/[.]pm\z/msx;
                my $code = path($_)->slurp;
                $code =~ s/^__END__$ .*//msx;
                my @keys = $code =~ /'((?:config|mail|readiness)[.]\w+)'/gmsx;
                @asked{@keys} = (1) x @keys;
            },
        },
        'lib'
    );
    ok( scalar keys %asked, 'the code asks for messages by key' );
    is_deeply( [ grep { !exists $english{$_} } sort keys %asked ],
        [], 'and each one is there' );
};

subtest 'the language is the one LC_ALL, LC_MESSAGES or LANG names' => sub {
    for my $case (
        [ { LANG => 'it_IT.UTF-8' },                           'it' ],
        [ { LANG => 'it' },                                    'it' ],
        [ { LANG => 'it_CH' },                                 'it' ],
        [ { LANG => 'en_GB.UTF-8' },                           'en' ],
        [ { LANG => 'C' },                                     'en' ],
        [ {},                                                  'en' ],
        [ { LANG => 'it_IT.UTF-8', LC_ALL => 'C' },            'en' ],
        [ { LANG => 'en_US.UTF-8', LC_MESSAGES => 'it_IT' },   'it' ],
        [ { LC_ALL => q{}, LANG => 'it_IT.UTF-8' },            'it' ],
        [ { LC_ALL => 'en_US.UTF-8', LC_MESSAGES => 'it_IT' }, 'en' ],
        [ { LANG => 'italian' },                               'en' ],
      )
    {
        my ( $environment, $language ) = @{$case};
        my $named = join q{ },
          map { "$_=$environment->{$_}" } sort keys %{$environment};
        is( GPForum::Service::I18N::CliCatalog->language_of($environment),
            $language, ( $named || 'nothing set' ) . " speaks $language" );
    }
};

subtest 'a report reads in the language chosen' => sub {
    my $problems = [
        {
            key        => 'config.required_in',
            variable   => 'GPFORUM_METRICS_TOKEN',
            parameters => { environment => 'production' },
            generate   => 'openssl rand -hex 32',
        }
    ];
    is(
        GPForum::Service::I18N::CliCatalog->new( language => 'it' )
          ->config_report($problems),
        join( "\n",
            'Le impostazioni di GPForum vanno sistemate:',
            q{},
            "  GPFORUM_METRICS_TOKEN \N{LATIN SMALL LETTER E WITH GRAVE}"
              . ' obbligatoria in production.',
            '    Generane uno con: openssl rand -hex 32',
            q{},
            q{Impostale nel file d'ambiente del servizio}
              . ' (deploy/gpforum.env.example descrive ogni impostazione),'
              . ' poi riprova.' )
          . "\n",
        'in Italian'
    );
    is(
        GPForum::Service::I18N::CliCatalog->new( language => 'en' )
          ->config_report($problems),
        GPForum::Config::Report->render($problems),
        'and in English, as GPForum::Config itself words it'
    );
    is(
        GPForum::Service::I18N::CliCatalog->new( language => 'it' )
          ->text('no.such.key'),
        'no.such.key',
        'a key nobody knows comes back as it is'
    );
};

done_testing();

# A message's placeholders, sorted, as one string.
sub _placeholders ($text) {
    my @names = ( $text // q{} ) =~ /$PLACEHOLDER/gmsx;

    return join q{,}, sort @names;
}

1;
