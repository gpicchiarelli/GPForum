# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::QueryPlanEvidence;

use Carp qw(croak);
use Const::Fast;
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Benchmark::Measure   qw(list_text overall_status);
use GPForum::Benchmark::PlanRules qw(
  analyze_plan depth_evidence failure_rule small_table_scans_are_warnings
  unindexable
);
use GPForum::Benchmark::QueryPlanEndpoints qw(
  endpoint_definition endpoint_names read_deep_page
);
use GPForum::Command::PerformanceSeed;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Schema;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;

const my %SWITCH_OPTION => (
    '--analyze'    => { analyze => 1 },
    '--check'      => { check   => 1 },
    '--dry-run'    => { dry_run => 1 },
    '--help'       => { help    => 1 },
    '--json'       => { format  => 'json' },
    '--no-analyze' => { analyze => 0 },
);

has dbh    => undef;    # optional: a test passes one; else the schema's
has schema => undef;    # optional: connected from the environment otherwise

# The deep pages the report being taken has read, by kind of list: two
# endpoints that page the same list page it at the same cursor.
has deep_pages => sub { return {}; };

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
    if ( $options->{help} ) {
        print _usage(), "\n" or croak 'failed to write usage';
        return 0;
    }

    my $report;
    try {
        $report = $self->evidence_report($options);
    }
    catch ($error) {
        print {*STDERR}
          'script/query-plan-evidence: PostgreSQL query plan evidence failed. '
          . 'Run script/bootstrap-deps --postgres, apply migrations, '
          . 'seed benchmark data, and ensure the database is reachable. Error: '
          . $error
          or croak 'failed to write the query plan error';
        return $EXIT_USAGE;
    };

    print $self->format_report( $report, $options->{format} )
      or croak 'failed to write query plan evidence report';

    return $options->{check} && $report->{status} ne 'ok' ? 1 : 0;
}

sub evidence_report ( $self, $options ) {
    $options->{profile} ||= 'small';
    my @endpoints =
        @{ $options->{endpoints} }
      ? @{ $options->{endpoints} }
      : endpoint_names();
    if ( $options->{dry_run} ) {
        return _dry_run_report( \@endpoints, $options );
    }

    my $dbh = $self->dbh || $self->_schema->storage->dbh;
    $self->deep_pages( {} );
    my @reports;
    for my $endpoint (@endpoints) {
        push @reports, $self->_endpoint_report( $dbh, $endpoint, $options );
    }

    my $dsn = GPForum::Config->from_environment->database_dsn;
    $dsn =~ s/(password=)[^;]+/${1}<redacted>/gmsx;

    return {
        status       => overall_status( \@reports ),
        mode         => 'postgres',
        analyze      => $options->{analyze} ? 1 : 0,
        dsn          => $dsn,
        endpoints    => \@reports,
        checked_at   => 'runtime',
        dataset      => { profile => $options->{profile} },
        failure_rule => failure_rule(),
    };
}

sub format_report ( $self, $report, $format ) {
    return encode_json($report) . "\n" if $format eq 'json';

    return _text_report($report);
}

# A deep endpoint EXPLAINs two pages of the same list: the first, and one
# halfway down it. The deep page's plan is judged like any other; the first
# page's is the baseline the deep page's filtering is compared with.
sub _endpoint_report ( $self, $dbh, $endpoint, $options ) {
    my $definition = _endpoint_definition($endpoint);

    # A deep endpoint's page is read once per report for each kind of list,
    # and the first page of that list is planned beside it.
    my $kind = $definition->{deep};
    my $page =
      defined $kind
      ? ( $self->deep_pages->{$kind} //= read_deep_page( $dbh, $kind ) )
      : undef;
    my $statement = $self->_statement( $definition, $page );
    my $first =
        $page && defined $page->{after}
      ? $self->_statement( $definition, { %{$page}, after => undef } )
      : undef;
    my $explained = _explain( $dbh, $statement, $options, $first );
    my $plan      = decode_json( $explained->{plan} )->[0];
    my $analysis  = analyze_plan( $definition, $statement, $plan );
    small_table_scans_are_warnings( $dbh, $analysis, $definition );
    push @{ $analysis->{violations} },
      unindexable( $definition, decode_json( $explained->{forced} )->[0] );
    my $depth =
      $page
      ? depth_evidence( $dbh, $analysis, $page,
        { deep => $plan, _first_page_plan( $explained, $first, $statement ) } )
      : undef;
    $analysis->{status} = @{ $analysis->{violations} } ? 'fail' : 'ok';

    return {
        endpoint   => $endpoint,
        status     => $analysis->{status},
        purpose    => $definition->{purpose},
        sql_label  => $definition->{sql_label},
        violations => $analysis->{violations},
        warnings   => $analysis->{warnings},
        summary    => {
            root_node      => $plan->{Plan}{'Node Type'},
            plan_rows      => $plan->{Plan}{'Plan Rows'}         || 0,
            actual_rows    => $plan->{Plan}{'Actual Rows'}       || 0,
            total_cost     => $plan->{Plan}{'Total Cost'}        || 0,
            actual_time_ms => $plan->{Plan}{'Actual Total Time'} || 0,
            shared_hit     => $plan->{Plan}{'Shared Hit Blocks'}  // 0,
            shared_read    => $plan->{Plan}{'Shared Read Blocks'} // 0,
            ( $depth ? ( depth => $depth ) : () ),
        },
    };
}

# The first page's plan, and whether the reader made the two pages one
# statement.
sub _first_page_plan ( $explained, $first, $statement ) {
    return if !$first;

    return (
        first          => decode_json( $explained->{first} )->[0],
        same_statement => (
            join( "\0", map { $_ // q{} } @{$first} ) eq
              join( "\0", map { $_ // q{} } @{$statement} ) ? 1 : 0
        ),
    );
}

# Rendering a resultset's SQL needs the schema but not a connection, so a
# report run against an injected handle still EXPLAINs the application's SQL.
sub _schema ($self) {
    if ( !$self->schema ) {
        $self->schema(
            GPForum::Schema->connect_from_config(
                GPForum::Config->from_environment
            )
        );
    }

    return $self->schema;
}

# What the application executes for the endpoint: the resultset lib/ builds,
# as DBIx::Class renders it, or -- where lib/ issues raw SQL -- lib/'s own
# statement. Nothing is transcribed, so changing a reader's query changes what
# this gate EXPLAINs. A deep endpoint's resultset takes the page it is
# asked for. Returns [ $sql, @bind ].
sub _statement ( $self, $definition, $page = undef ) {
    return $definition->{statement}->() if $definition->{statement};

    my ( $sql, @bind ) = @{
        ${
            $definition->{resultset}
              ->( $self->_schema, ( $page ? ($page) : () ) )->as_query
        }
    };

    return [ $sql, map { ref $_ eq 'ARRAY' ? $_->[1] : $_ } @bind ];
}

# Two plans of the same statement. The first is the planner's own choice,
# which carries the timings and row counts. The second is taken with
# sequential scans disabled: a sequential scan that survives that means no
# index can answer the query at all -- a fact about the schema, true on a
# ten-row test database and on a production one alike, where the first plan's
# row thresholds only notice once the table is already large.
#
# EXPLAIN ANALYZE executes the statement, and the outbox claim is an UPDATE.
# Every plan is taken inside a transaction that is rolled back, so gathering
# evidence never changes the data it measures, and SET LOCAL ends with it. A
# deep endpoint's first page is planned there too, before the forced plan.
sub _explain ( $dbh, $statement, $options, $first = undef ) {
    my $flags =
      $options->{analyze}
      ? 'ANALYZE, BUFFERS, FORMAT JSON'
      : 'BUFFERS, FORMAT JSON';
    my ( $sql, @bind ) = @{$statement};

    $dbh->begin_work;
    my ( %plans, $error );
    try {
        if ($first) {
            my ( $first_sql, @first_bind ) = @{$first};
            $plans{first} =
              $dbh->selectrow_array( "EXPLAIN ($flags) $first_sql",
                undef, @first_bind );
        }
        $plans{plan} =
          $dbh->selectrow_array( "EXPLAIN ($flags) $sql", undef, @bind );
        $dbh->do('SET LOCAL enable_seqscan = off');
        $plans{forced} =
          $dbh->selectrow_array( "EXPLAIN (FORMAT JSON) $sql", undef, @bind );
    }
    catch ($caught) {
        $error = $caught;
    };
    $dbh->rollback;
    croak $error if defined $error;

    return \%plans;
}

sub _dry_run_report ( $endpoints, $options ) {
    my @reports;
    for my $endpoint ( @{$endpoints} ) {
        my $definition = _endpoint_definition($endpoint);
        push @reports,
          {
            endpoint   => $endpoint,
            status     => 'ok',
            purpose    => $definition->{purpose},
            sql_label  => $definition->{sql_label},
            violations => [],
            warnings   => [],
          };
    }

    return {
        status    => 'ok',
        mode      => 'dry-run',
        analyze   => $options->{analyze} ? 1 : 0,
        dataset   => { profile => $options->{profile} },
        endpoints => \@reports,
    };
}

sub _endpoint_definition ($endpoint) {
    return endpoint_definition($endpoint)
      // GPForum::X::Usage->throw( message => _usage() );
}

sub _text_report ($report) {
    my $text =
        'query_plan_evidence status='
      . $report->{status}
      . ' mode='
      . $report->{mode}
      . ' analyze='
      . $report->{analyze}
      . ' dataset_profile='
      . $report->{dataset}{profile} . "\n";

    for my $endpoint ( @{ $report->{endpoints} } ) {
        $text .= join q{ },
          'endpoint=' . $endpoint->{endpoint},
          'status=' . $endpoint->{status},
          'sql_label=' . $endpoint->{sql_label},
          'violations=' . list_text( $endpoint->{violations} ),
          'warnings=' . list_text( $endpoint->{warnings} ),
          _depth_text( $endpoint->{summary} ),
          "\n";
    }

    return $text;
}

# How deep a deep endpoint paged and what each page filtered, so a CI log
# shows whether the deep-page rule had anything to measure.
sub _depth_text ($summary) {
    my $depth = $summary ? $summary->{depth} : undef;
    return if !$depth;

    my @text = ( 'depth=' . $depth->{rows_before_cursor} );
    if ( defined $depth->{rows_removed_deep_page} ) {
        push @text, sprintf 'rows_removed=%.0f/%.0f',
          @{$depth}{qw(rows_removed_first_page rows_removed_deep_page)};
    }

    return @text;
}

sub _options (@arguments) {
    my $usage = _usage();

    return GPForum::Command::Usage->parse_options(
        \@arguments,
        {
            analyze   => 1,
            check     => 0,
            dry_run   => 0,
            endpoints => [],
            format    => 'text',
            help      => 0,
            profile   => 'small',
        },
        {
            usage    => $usage,
            switches => \%SWITCH_OPTION,
            values   => {
                '--endpoint' => sub ( $options, $value ) {
                    push @{ $options->{endpoints} },
                      GPForum::Command::Usage->option_choice( $value,
                        [ endpoint_names() ], $usage );
                },
                '--profile' => sub ( $options, $value ) {
                    $options->{profile} =
                      GPForum::Command::Usage->option_choice( $value,
                        [ GPForum::Command::PerformanceSeed->profiles ],
                        $usage );
                },
            },
        },
    );
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
      . ' [--dry-run] [--json] [--check] [--analyze] [--no-analyze] [--profile small|medium|hot-thread] [--endpoint NAME] ...';
}

1;
