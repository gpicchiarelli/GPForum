# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::PerformanceSeed;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(encode_json);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Benchmark::SeedDataset qw(dataset_counts insert_dataset seed_id);
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Schema;
use GPForum::X::Config;

our $VERSION = '0.001';

const my $DEFAULT_USERS            => 5;
const my $DEFAULT_CATEGORIES       => 3;
const my $DEFAULT_THREADS          => 12;
const my $DEFAULT_POSTS_PER_THREAD => 8;
const my $PROFILE_SMALL            => 'small';
const my $PROFILE_MEDIUM           => 'medium';
const my $PROFILE_HOT_THREAD       => 'hot-thread';
const my @PROFILES => ( $PROFILE_SMALL, $PROFILE_MEDIUM, $PROFILE_HOT_THREAD );
const my %PROFILE_DATASET => (
    $PROFILE_MEDIUM =>
      { users => 25, categories => 8, threads => 120, posts_per_thread => 15 },
    $PROFILE_HOT_THREAD =>
      { users => 10, categories => 3, threads => 30, posts_per_thread => 120 },
);
const my %SWITCH_OPTION => (
    '--dry-run' => { dry_run => 1 },
    '--json'    => { format  => 'json' },
    '--help'    => { help    => 1 },
);
const my $HTTP_EXIT_USAGE => 2;
const my @REPORTED_COUNTS => qw(
  users categories threads posts sessions read_states notifications bookmarks
  subscriptions reports moderation_actions
);

has schema => undef;    # optional: connected from the environment otherwise

# Misuse becomes the documented usage exit instead of an uncaught exception:
# same text, on stderr, status 2, without croak's " at FILE line N". Anything
# else is rethrown, so a real failure is not relabelled as misuse.
sub run ( $self, @arguments ) {
    my $status;
    try {
        $status = $self->_run(@arguments);
    }
    catch ($error) {
        my $text = GPForum::Command::Usage->trimmed($error);
        die "$text\n" if !GPForum::Command::Usage->is_usage($error);

        return GPForum::Command::Usage->error( undef, $text );
    };

    return $status;
}

sub _run ( $self, @arguments ) {
    my $options = _options(@arguments);
    return _print_usage()                             if $options->{help};
    return _print_report( _plan($options), $options ) if $options->{dry_run};

    my $report;
    try {
        $report = $self->seed($options);
    }
    catch ($error) {
        print {*STDERR} _seed_error($error)
          or croak 'failed to write the seed error';
        return $HTTP_EXIT_USAGE;
    };

    return _print_report( $report, $options );
}

sub seed ( $self, $options ) {
    my $plan = _plan($options);
    my $dbh  = $self->_dbh;

    _assert_migrated($dbh);
    _with_transaction( $dbh, sub { _insert_dataset( $dbh, $plan ); } );

    return $plan;
}

# The dataset a named profile seeds -- the numbers --profile gives -- for the
# benchmarks that seed before they measure, so they keep no copy of them.
sub seed_profile ( $self, $profile ) {
    return $self->seed( _options( '--profile', $profile ) );
}

# The profile names --profile accepts, for the commands that pass one on.
sub profiles ($class) {
    return @PROFILES;
}

sub _dbh ($self) {
    my $schema = $self->schema;
    if ( !$schema ) {
        my $config = GPForum::Config->from_environment;
        $schema = GPForum::Schema->connect_from_config($config);
    }

    return $schema->storage->dbh;
}

sub _with_transaction ( $dbh, $code ) {
    $dbh->begin_work;
    try {
        $dbh->do('SET CONSTRAINTS ALL DEFERRED');
        $code->();
        $dbh->commit;
    }
    catch ($error) {

        # A rollback that fails too must not hide why the seed failed.
        try {
            $dbh->rollback;
        }
        catch ($rollback_error) {
        };
        croak $error;
    };

    return;
}

# The dataset the plan describes, in the seed's transaction; t/369 inserts it
# into a recording handle.
sub _insert_dataset ( $dbh, $plan ) {
    return insert_dataset( $dbh, $plan );
}

sub _assert_migrated ($dbh) {
    for my $table (
        qw(
        users roles permissions role_bindings categories threads posts
        thread_read_state bookmarks subscriptions reports moderation_actions
        )
      )
    {
        my $exists = $dbh->selectrow_array( q{SELECT to_regclass(?)},
            undef, 'public.' . $table );
        if ( !$exists ) {
            GPForum::X::Config->throw( message =>
'database schema is not migrated; run script/gpforum-carton exec bin/gpforum-migrate --apply'
            );
        }
    }

    return;
}

sub _plan ($options) {
    return {
        status  => $options->{dry_run} ? 'dry-run' : 'seeded',
        profile => $options->{profile},
        dataset => dataset_counts($options),
        routes  => _routes(),
    };
}

sub _routes {
    return {
        home         => q{/},
        categories   => q{/categories},
        category     => q{/c/} . seed_id( category => 1 ),
        thread       => q{/t/} . seed_id( thread   => 1 ),
        search       => q{/search?q=performance},
        health       => q{/health},
        health_ready => q{/health/ready},
        metrics      => q{/metrics},
    };
}

sub _options (@arguments) {
    my $usage  = _usage();
    my %values = (
        '--profile' => sub ( $options, $value ) {
            $options->{profile} =
              GPForum::Command::Usage->option_choice( $value, \@PROFILES,
                $usage );
        },
    );

    # A number of its own makes the dataset a custom one; a --profile given
    # after it still wins, as the last word on the command line.
    for my $option (qw(users categories threads posts-per-thread)) {
        my $key = $option =~ tr/-/_/r;
        $values{"--$option"} = sub ( $options, $value ) {
            $options->{$key} =
              GPForum::Command::Usage->option_number( $value,
                'positive_integer', $usage );
            $options->{profile} = 'custom';
        };
    }

    my $options = GPForum::Command::Usage->parse_options(
        \@arguments,
        {
            users            => $DEFAULT_USERS,
            categories       => $DEFAULT_CATEGORIES,
            threads          => $DEFAULT_THREADS,
            posts_per_thread => $DEFAULT_POSTS_PER_THREAD,
            profile          => $PROFILE_SMALL,
            format           => 'text',
            dry_run          => 0,
            help             => 0,
        },
        { usage => $usage, switches => \%SWITCH_OPTION, values => \%values },
    );

    # The defaults are the small profile; the larger ones replace them.
    if ( exists $PROFILE_DATASET{ $options->{profile} } ) {
        %{$options} =
          ( %{$options}, %{ $PROFILE_DATASET{ $options->{profile} } } );
    }

    return $options;
}

sub _print_report ( $report, $options ) {
    my $text =
      $options->{format} eq 'json'
      ? encode_json($report) . "\n"
      : _text_report($report);

    print $text or croak 'failed to write performance seed report';

    return 0;
}

sub _text_report ($report) {
    my ( $dataset, $routes ) = @{$report}{qw(dataset routes)};

    return join q{},
      "performance_seed status=$report->{status}\n",
      "profile=$report->{profile}\n",
      join( q{ }, map { "$_=$dataset->{$_}" } @REPORTED_COUNTS ), "\n",
      map { "${_}_route=$routes->{$_}\n" } qw(category thread search);
}

sub _print_usage {
    print _usage(), "\n" or croak 'failed to write usage';

    return 0;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return
        'Usage: '
      . GPForum::Command::Usage->program
      . ' [--dry-run] [--json] [--profile small|medium|hot-thread] [--users N] [--categories N] [--threads N] [--posts-per-thread N]';
}

sub _seed_error ($error) {
    return
        'script/seed-performance-data: PostgreSQL seed failed. '
      . 'Ensure DBD::Pg is installed with script/bootstrap-deps --postgres, '
      . 'the database is reachable, and migrations are applied. Error: '
      . $error;
}

1;
