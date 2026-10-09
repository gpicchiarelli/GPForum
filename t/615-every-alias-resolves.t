# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Mojo::File qw(path);
use Test::More;
use version;

use lib 'lib';

use GPForum;
use GPForum::Config;

our $VERSION = '0.001';

# An install still carrying an old name starts, and is told the line that
# replaces it (audit 5.6). Each old name and old value is in the settings
# table's aliases, read until its release; this test reads each one as an
# old environment file would, until that release, and then fails, so the
# alias is removed in the release that says it is. docs/DEPLOYMENT.md's
# "Renamed settings" names each one for the operator.

const my $GUIDE => 'docs/DEPLOYMENT.md';
const my %SECRETS => (
    GPFORUM_MAIL_FROM       => 'forum@forum.gpforum.test',
    GPFORUM_METRICS_TOKEN   => 'metrics-token',
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.test',
    GPFORUM_SESSION_SECRET  => '0123456789abcdef' x 3,
);

my $release = version->parse($GPForum::VERSION);
my @aliases = map { _aliases_of($_) } @{ GPForum::Config->settings };
ok( @aliases, 'the table has old names to read' );

for my $alias (@aliases) {
    my $setting = $alias->{setting};
    my $old =
      exists $alias->{env} ? $alias->{env} : "$setting->{env}=$alias->{value}";
    subtest $old => sub {
        cmp_ok( version->parse( $alias->{read_until} ),
            '>', $release, "read until $alias->{read_until}, after $release" );

        my ( $environment, $expected ) = _old_environment( $setting, $alias );
        my $config = GPForum::Config->from_environment(
            { %SECRETS, GPFORUM_ENV => 'production', %{$environment} } );
        my $name = $setting->{name};
        is( $config->$name, $expected, "reads as $setting->{env}=$expected" );
        my ($noted) =
          grep { $_->{setting} eq $name } @{ $config->renamed_settings };
        ok( $noted, 'and is noted for the warning' );
        is( $noted && $noted->{replacement},
            $setting->{env}, 'naming the setting it now is' );
    };
}

subtest "$GUIDE, Renamed settings: a row for each" => sub {
    my ($table) =
      path($GUIDE)->slurp =~
      /^ [#]{2,3} [ ] Renamed [ ] settings \n (.*?) ^ [#]/msx;
    ok( defined $table, 'the section is there' );
    for my $alias (@aliases) {
        my $old =
          exists $alias->{env}
          ? $alias->{env}
          : "$alias->{setting}{env}=$alias->{value}";
        like(
            $table // q{},
            qr/^ [|] [ ] `\Q$old\E` [ ] [|]/msx,
            "$old has its row"
        );
    }
};

done_testing();

# A setting's aliases, each with the setting it belongs to.
sub _aliases_of ($setting) {
    return map { +{ %{$_}, setting => $setting } } @{ $setting->{aliases} };
}

# The environment an old file holds for an alias, and the value it reads as:
# an old variable with one of its words, or an old value of the variable.
sub _old_environment ( $setting, $alias ) {
    if ( exists $alias->{env} ) {
        my ($word) = sort keys %{ $alias->{values} };
        return ( { $alias->{env} => $word }, $alias->{values}{$word} );
    }

    return ( { $setting->{env} => $alias->{value} }, $alias->{as} );
}

1;
