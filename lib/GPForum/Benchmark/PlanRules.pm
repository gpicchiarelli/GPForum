# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Benchmark::PlanRules;

use v5.40;

use Const::Fast;
use Exporter qw(import);

use GPForum::Benchmark::QueryPlanEndpoints qw(page_rows);

our $VERSION = '0.001';

our @EXPORT_OK = qw(
  analyze_plan
  depth_evidence
  failure_rule
  relation_size
  small_table_scans_are_warnings
  unindexable
);

const my $PLAN_ROWS_SEQ_OK    => 100;
const my $PLAN_ROWS_SORT_OK   => 1_000;
const my $PLAN_ROWS_NESTED_OK => 5_000;

# A sequential scan fails the gate only on a table larger than this. Below
# it a table is a few hundred pages at most, and reading it whole is often
# the planner's right answer: the medium dataset's 120 threads and 1,800 post
# bodies failed the gate on plans that were correct. Whether any index can
# answer the query at all is the forced plan's question, at every size.
const my $SMALL_RELATION_ROWS => 10_000;
const my $RELATION_ROWS_SQL => join q{ },
  q{SELECT greatest(c.reltuples, coalesce(s.n_live_tup, 0))::bigint},
  q{FROM pg_class c LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid},
  q{WHERE c.oid = to_regclass(?)};
const my $SQL_PAGE_SKIP_KEYWORD => join q{}, 'OFF', 'SET';

# A keyset page costs the same at any depth only if its scan starts at the
# cursor; one that reads its way there filters out every row before it. A
# deep page may filter out a page's worth of rows more than the first page --
# hidden posts, the row equal to the cursor -- and no more. With fewer than
# $DEEP_PAGE_MIN_ROWS rows before the cursor a scan that reads its way there
# hardly exceeds that allowance, and the evidence says so instead of passing
# quietly: the small seed's longest thread has eight posts.
const my $DEPTH_FILTER_SLACK => page_rows();
const my $DEEP_PAGE_MIN_ROWS => 2 * page_rows();

# Tables small by construction, where a sequential scan is the right plan
# whatever the forum's size: categories are created by an administrator.
const my %ALLOWED_SEQ_SCAN_RELATION => map { $_ => 1 }
  qw(schema_versions projection_offsets projection_generations categories);

# The thresholds a report states it judged its plans by.
sub failure_rule {
    return {
        seq_scan_plan_rows     => $PLAN_ROWS_SEQ_OK,
        seq_scan_relation_rows => $SMALL_RELATION_ROWS,
        sort_plan_rows         => $PLAN_ROWS_SORT_OK,
        nested_loop_plan_rows  => $PLAN_ROWS_NESTED_OK,
        deep_page_filter_rows  => $DEPTH_FILTER_SLACK,
        deep_page_min_rows     => $DEEP_PAGE_MIN_ROWS,
    };
}

sub unindexable ( $definition, $forced ) {
    return if $definition->{allow_seq_scan};

    my @relations;
    _walk_plan(
        $forced->{Plan},
        sub {
            my ($node) = @_;
            my $relation = $node->{'Relation Name'} || q{};
            if ( ( $node->{'Node Type'} || q{} ) eq 'Seq Scan'
                && !exists $ALLOWED_SEQ_SCAN_RELATION{$relation} )
            {
                push @relations, $relation;
            }
        }
    );

    return map { "no_usable_index:$_" } @relations;
}

sub analyze_plan ( $definition, $statement, $plan ) {
    my @warnings;
    my @violations;
    _walk_plan(
        $plan->{Plan},
        sub {
            my ($node) = @_;
            push @violations, _node_violations( $definition, $node );

            # A bitmap heap scan over many rows is worth a look, not wrong.
            if ( ( $node->{'Node Type'} || q{} ) eq 'Bitmap Heap Scan'
                && _node_rows($node) > $PLAN_ROWS_SORT_OK )
            {
                push @warnings, 'bitmap_heap_scan';
            }
        }
    );
    if ( $statement->[0] =~ /\b \Q$SQL_PAGE_SKIP_KEYWORD\E \b/imsx ) {
        push @violations, 'offset_in_hot_query';
    }

    return {
        status     => @violations ? 'fail' : 'ok',
        violations => \@violations,
        warnings   => \@warnings,
    };
}

sub _node_violations ( $definition, $node ) {
    my @violations;
    my $type     = $node->{'Node Type'}     || q{};
    my $relation = $node->{'Relation Name'} || q{};
    my $rows     = _node_rows($node);

    if ( $type eq 'Seq Scan'
        && !_seq_scan_allowed( $definition, $relation, $rows ) )
    {
        # Actual Rows is an average per loop, printed with decimals: a
        # parallel scan's workers each read a share of the table.
        my $scanned =
            $node->{'Parallel Aware'}
          ? $rows * ( $node->{'Actual Loops'} || 1 )
          : $rows;
        push @violations, sprintf 'seq_scan:%s:%.0f', $relation, $scanned;
    }
    if ( $type eq 'Sort' && $rows > $PLAN_ROWS_SORT_OK ) {
        push @violations, 'heavy_sort:' . $rows;
    }
    if (   $type eq 'Nested Loop'
        && $rows > $PLAN_ROWS_NESTED_OK
        && _node_rows( _outer_child($node) ) > 1 )
    {
        # A loop over one outer row -- the one space a search joins -- is a
        # join against a constant, however many rows it passes through.
        push @violations, 'explosive_nested_loop:' . $rows;
    }

    return @violations;
}

# The outer side of a join. EXPLAIN lists a node's InitPlans before its
# outer and inner children, so it is found by role, not by position.
sub _outer_child ($node) {
    my @children = @{ $node->{Plans} || [] };
    my ($outer) =
      grep { ( $_->{'Parent Relationship'} // q{} ) eq 'Outer' } @children;

    return $outer || $children[0] || {};
}

sub _seq_scan_allowed ( $definition, $relation, $rows ) {
    return 1 if exists $ALLOWED_SEQ_SCAN_RELATION{$relation};
    return 1 if $definition->{allow_seq_scan};
    return 1 if $rows <= $PLAN_ROWS_SEQ_OK;

    return 0;
}

sub _node_rows ($node) {
    return $node->{'Actual Rows'} if defined $node->{'Actual Rows'};
    return $node->{'Plan Rows'}   if defined $node->{'Plan Rows'};

    return 0;
}

sub _walk_plan ( $node, $visitor ) {
    return if !$node;

    $visitor->($node);
    for my $child ( @{ $node->{Plans} || [] } ) {
        _walk_plan( $child, $visitor );
    }

    return;
}

# A sequential scan is recorded, not failed, when it is the planner's right
# answer: the table is small, or it is the relation a relevance-ordered query
# ranks and the scan returns at least half of it -- a word every document
# holds. Only that relation: the search's joins (its authors, say) are read
# whole by construction, and a latest-first page that reads a whole table to
# sort it is exactly a missing index. An unknown table counts as large; one
# the catalog says holds fewer rows than the scan returned -- never analysed,
# its counters lost -- is at least as large as the scan.
sub small_table_scans_are_warnings ( $dbh, $analysis, $definition ) {
    my @violations;
    for my $violation ( @{ $analysis->{violations} } ) {
        my ( $relation, $rows ) =
          $violation =~ /\A seq_scan: (.+) : (\d+) \z/msx;
        if ( !defined $relation ) {
            push @violations, $violation;
            next;
        }
        my $size = relation_size( $dbh, $relation, $rows );
        if ( defined $size && $size <= $SMALL_RELATION_ROWS ) {
            push @{ $analysis->{warnings} }, "seq_scan_small_table:$relation";
            next;
        }
        if (   defined $size
            && ( $definition->{ranked_relation} // q{} ) eq $relation
            && $rows * 2 >= $size )
        {
            push @{ $analysis->{warnings} }, "seq_scan_most_rows:$relation";
            next;
        }
        push @violations, "seq_scan:$relation";
    }
    $analysis->{violations} = \@violations;

    return;
}

# The rows the catalog says a table holds, and at least the rows a scan of it
# read; undef for a table the catalog does not know.
sub relation_size ( $dbh, $relation, $scanned ) {
    my ($size) = $dbh->selectrow_array( $RELATION_ROWS_SQL, undef, $relation );
    return $size if !defined $size;

    return $size < $scanned ? $scanned : $size;
}

# Rows Removed by Filter needs ANALYZE; without it the growth is not
# measured, and the evidence says so. A cursor the reader would not decode
# leaves the first page's statement: a deep page that is not one.
sub depth_evidence ( $dbh, $analysis, $page, $plans ) {
    my $depth = { rows_before_cursor => $page->{depth} };
    if ( !defined $page->{after} ) {
        push @{ $analysis->{warnings} }, 'no_deep_page';
        return $depth;
    }
    if ( $plans->{same_statement} ) {
        push @{ $analysis->{violations} }, 'cursor_ignored';
        return $depth;
    }
    if ( $page->{depth} < $DEEP_PAGE_MIN_ROWS ) {
        push @{ $analysis->{warnings} }, "shallow_page:$page->{depth}";
    }
    if (   !defined $plans->{deep}{Plan}{'Actual Rows'}
        || !defined $plans->{first}{Plan}{'Actual Rows'} )
    {
        push @{ $analysis->{warnings} }, 'filter_growth_unmeasured';
        return $depth;
    }

    my ( $first, $deep ) =
      map { _rows_removed( $dbh, $plans->{$_}{Plan} ) } qw(first deep);
    $depth->{rows_removed_first_page} = $first->{counted};
    $depth->{rows_removed_deep_page}  = $deep->{counted};
    if ( $deep->{counted} - $first->{counted} > $DEPTH_FILTER_SLACK ) {
        push @{ $analysis->{violations} },
          sprintf 'filter_grows_with_depth:%.0f:%.0f', $first->{counted},
          $deep->{counted};
    }
    push @{ $analysis->{warnings} },
      _hidden_growth( $first->{read_whole}, $deep->{read_whole} );

    return $depth;
}

# The rows the page's scans read and threw away, EXPLAIN printing them per
# loop; what small tables read whole threw away is kept apart, by table.
sub _rows_removed ( $dbh, $root ) {
    my $removed = { counted => 0, read_whole => {} };
    _walk_plan(
        $root,
        sub {
            my ($node)   = @_;
            my $loops    = $node->{'Actual Loops'} || 1;
            my $filtered = ( $node->{'Rows Removed by Filter'} // 0 ) * $loops;
            return if !$filtered;
            if ( !_small_table_scan( $dbh, $node, $filtered, $loops ) ) {
                $removed->{counted} += $filtered;
                return;
            }
            my $relation = $node->{'Relation Name'} // q{};
            return if exists $ALLOWED_SEQ_SCAN_RELATION{$relation};
            $removed->{read_whole}{$relation} += $filtered;
        }
    );

    return $removed;
}

# A small table read whole filters out the rows before the cursor too, and
# the planner is right to read it so: the growth is hidden, not absent. The
# medium seed's latest list is read that way with its keyset bound or
# without, so the deep page says it could not tell, as a shallow one does.
# A table filtered alike on both pages -- the signed-in union's arm for the
# reader's own deleted threads -- hides nothing.
sub _hidden_growth ( $first, $deep ) {
    return map { "filter_growth_unmeasured:$_" }
      grep { $deep->{$_} - ( $first->{$_} // 0 ) > $DEPTH_FILTER_SLACK }
      sort keys %{$deep};
}

# A sequential scan of a small table reads all of it whatever the depth --
# the small seed's thread page filters out the other threads' posts on both
# pages -- and is the planner's right answer there. One of a large table
# counts like an index scan: leaving it to the sequential scan rule let a
# deep page through that read a large table to return fewer rows than that
# rule looks at.
sub _small_table_scan ( $dbh, $node, $filtered, $loops ) {
    return 0 if ( $node->{'Node Type'} // q{} ) ne 'Seq Scan';

    my $relation = $node->{'Relation Name'} // q{};
    return 1 if exists $ALLOWED_SEQ_SCAN_RELATION{$relation};

    my $size =
      relation_size( $dbh, $relation, $filtered + _node_rows($node) * $loops );

    return defined $size && $size <= $SMALL_RELATION_ROWS ? 1 : 0;
}

1;

__END__

=head1 NAME

GPForum::Benchmark::PlanRules - How the query plan evidence judges a plan.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    use GPForum::Benchmark::PlanRules qw(analyze_plan unindexable);

    my $analysis = analyze_plan( $definition, [ $sql, @bind ], $plan );
    push @{ $analysis->{violations} }, unindexable( $definition, $forced );

=head1 DESCRIPTION

The rules L<GPForum::Command::QueryPlanEvidence> applies to the EXPLAIN plans
it takes: a sequential scan of a large table, a heavy sort, an exploding
nested loop and a page skipped to by row count fail the plan; a table no index can answer fails
it whatever its size; a sequential scan the planner is right to choose -- a
small table, most of a ranked relation -- is a warning; and a deep page whose
scans filter out more rows than the first page's by more than a page fails
it. Every function is exported on request only.

=head1 SUBROUTINES/METHODS

=head2 analyze_plan

Given an endpoint definition, its statement (C<[ $sql, @bind ]>) and its
decoded plan, a hash reference with the plan's C<violations>, its
C<warnings> and its C<status>.

=head2 small_table_scans_are_warnings

Given a database handle, an analysis and the endpoint definition, turns each
C<seq_scan> violation over a table of at most 10,000 rows, or over most of the
relation the endpoint ranks, into a warning. Returns nothing.

=head2 unindexable

Given an endpoint definition and the plan taken with sequential scans
disabled, a C<no_usable_index:TABLE> violation for each table still scanned
sequentially, unless the endpoint allows it.

=head2 depth_evidence

Given a database handle, the deep page's analysis, the page and the plans
(C<deep>, C<first>, C<same_statement>), the C<depth> summary: how many rows
precede the cursor and what each page's scans filtered out. Adds the
violations and warnings the comparison finds to the analysis.

=head2 relation_size

Given a database handle, a table and the rows a scan of it read, the rows the
catalog says it holds and at least the rows read; undef for a table the
catalog does not know.

=head2 failure_rule

The thresholds, as a hash reference a report carries.

=head1 DIAGNOSTICS

None: a failing catalog query raises the handle's error.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<Exporter>, L<GPForum::Benchmark::QueryPlanEndpoints>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
