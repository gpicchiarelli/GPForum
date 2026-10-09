# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Schema;
use GPForum::Test::EngineeringCorrectness::Schema;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::UniqueKey;

our $VERSION = '0.001';

# DBIx::Class's find reads only the columns of a unique key the condition
# fully gives, ORing every such key, and searches on the whole condition only
# when it gives none. A fake find that matched every column it was given hid
# a store that looked a session up by its id and its member: DBIx::Class read
# the id alone. GPForum::Test::UniqueKey gives the doubles DBIx::Class's
# condition, and this test holds it to the condition DBIx::Class itself
# builds, for every result class and every unique key, with no database.
const my $EXTRA_COLUMN_VALUE => 'not-a-key-value';

# No statement runs: single is replaced to capture the condition find built.
my $schema =
  GPForum::Schema->connect('dbi:Pg:dbname=gpforum_no_database;port=1');

subtest 'the doubles build the condition DBIx::Class builds' => sub {
    for my $source_name ( sort $schema->sources ) {
        my $source = $schema->source($source_name);
        my $class  = $source->result_class;
        for my $case ( _cases($source) ) {
            my ( $label, @arguments ) = @{$case};
            is_deeply(
                GPForum::Test::UniqueKey::find_conditions( $class, @arguments ),
                _dbic_condition( $source_name, @arguments ),
                "$source_name: $label"
            );
        }
    }
};

subtest 'a key named with key must be fully given' => sub {
    my $real = _error(
        sub {
            $schema->resultset('User')
              ->find( { status => 'active' }, { key => 'primary' } );
        }
    );
    my $double = _error(
        sub {
            GPForum::Test::UniqueKey::find_conditions(
                'GPForum::Schema::Result::User',
                { status => 'active' },
                { key    => 'primary' }
            );
        }
    );
    my $missing_id =
      qr/missing [ ] values [ ] for [ ] column[(]s[)]: [ ] 'id'/msx;

    like( $real, $missing_id, 'DBIx::Class refuses it' );
    like(
        $double,
        qr/\A Unable [ ] to [ ] satisfy/msx,
        'and so does the double'
    );
    like( $double, $missing_id, 'in the same words' );
};

subtest 'a moderation resultset that knows its class finds by key' => sub {
    my $reports = GPForum::Test::ModerationResultSet->new(
        result_class => 'GPForum::Schema::Result::Report' );
    $reports->create(
        {
            report_id   => 'report-1',
            status      => 'open',
            target_type => 'post',
            target_id   => 'post-1',
        }
    );

    my $found =
      $reports->find( { report_id => 'report-1', status => 'resolved' } );
    ok( $found, 'a column outside the key does not hide the row' );
    is( $found && $found->get_column('status'),
        'open', 'it is the row the key names, as DBIx::Class returns it' );
    is( $reports->find('report-1')->get_column('report_id'),
        'report-1', 'a primary key value finds it' );
    is( $reports->find('report-2'), undef, 'another key finds nothing' );
};

subtest 'the engineering resultset finds by key too' => sub {
    my $doubles = GPForum::Test::EngineeringCorrectness::Schema->new;
    $doubles->resultset('Session')->create(
        {
            session_id => 'session-1',
            user_id    => 'user-1',
            revoked_at => undef,
        }
    );

    my $found = $doubles->resultset('Session')
      ->find( { session_id => 'session-1', user_id => 'user-2' } );
    is( $found && $found->get_column('user_id'),
        'user-1', 'the session id alone decides, whoever the member is' );
};

done_testing();

sub _error ($code) {
    my $error = q{};
    try {
        $code->();
    }
    catch ($caught) {
        $error = "$caught";
    };

    return $error;
}

# For each unique key: its columns, then its columns plus a column outside
# every key, then its values in order; and a condition naming no key.
sub _cases ($source) {
    my @cases;
    my %keyed = map { $_ => 1 }
      map { $source->unique_constraint_columns($_) }
      $source->unique_constraint_names;
    my ($extra) = grep { !$keyed{$_} } sort $source->columns;

    for my $name ( sort $source->unique_constraint_names ) {
        my @columns = $source->unique_constraint_columns($name);
        my %given   = map { $_ => "$name-$_" } @columns;
        push @cases, [ "$name columns", {%given} ];
        if ($extra) {
            push @cases,
              [
                "$name columns and $extra",
                { %given, $extra => $EXTRA_COLUMN_VALUE }
              ];
        }
        push @cases,
          [ "$name values", ( map { $given{$_} } @columns ), { key => $name } ];
    }
    if ($extra) {
        push @cases, [ "$extra alone", { $extra => $EXTRA_COLUMN_VALUE } ];
    }

    return @cases;
}

# The condition DBIx::Class's find passes on, as alternatives without the
# me. qualifier and the = operator it adds.
sub _dbic_condition ( $source_name, @arguments ) {
    my $where;
    {
        no warnings 'redefine';    ## no critic (TestingAndDebugging::ProhibitNoWarnings)
        local *DBIx::Class::ResultSet::single = sub ( $resultset, @ ) {
            $where = $resultset->{attrs}{where};
            return undef;
        };
        $schema->resultset($source_name)->find(@arguments);
    }

    my @alternatives = ref $where eq 'ARRAY' ? @{$where} : ($where);

    return [ map { _plain($_) } @alternatives ];
}

sub _plain ($condition) {
    my %plain;
    for my $column ( keys %{$condition} ) {
        my $value = $condition->{$column};
        if ( ref $value eq 'HASH' && exists $value->{q{=}} ) {
            $value = $value->{q{=}};
        }
        $plain{ $column =~ s/\A me[.]//msxr } = $value;
    }

    return \%plain;
}

1;
