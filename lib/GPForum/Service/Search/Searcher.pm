# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Search::Searcher;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Infrastructure::Row;
use GPForum::Service::Search::DocumentBuilder;
use Mojo::Date;
use Mojo::Util  qw(html_unescape xml_escape);
use Time::Local qw(timegm_modern);

our $VERSION = '0.001';

const my $DEFAULT_LIMIT      => 20;
const my $MAX_LIMIT          => 50;
const my $DEFAULT_CANDIDATES => 1_000;
const my $SNIPPET_RADIUS     => 80;
const my $SNIPPET_MAX_LENGTH => 220;
const my $EMPTY_TEXT         => q{};
const my $SPACE              => q{ };
const my $ELLIPSIS           => q{...};
const my $SECONDS_PER_DAY    => 86_400;
const my $GMTIME_BASE_YEAR   => 1_900;
const my $EPOCH_YEAR         => 1_970;
const my $MICROSECOND_DIGITS => 6;

# What a filter may be before it is bound. Each was bound as it came, so
# from=garbage reached PostgreSQL, which refused it: the page degraded and the
# log line quoted what the visitor had typed. /a: a POSIX class would match
# any script's digits otherwise, and PostgreSQL reads ASCII ones only.
const my $UUID_FILTER =>
  qr/\A [[:xdigit:]]{8} (?: - [[:xdigit:]]{4} ){3} - [[:xdigit:]]{12} \z/amsx;
const my $DAY_FILTER =>
  qr/\A ([[:digit:]]{4}) - ([[:digit:]]{2}) - ([[:digit:]]{2}) \z/amsx;

# An RFC 3339 time, whole, which Mojo::Date then parses and range-checks.
# Its own pattern takes a year, and an offset's hours and minutes, of any
# length: a year past PostgreSQL's range, or an offset of a hundred billion
# hours (-99999999999:00), failed there just as the garbage did, and a
# longer offset was past gmtime's too. The offset is RFC 3339's, at most
# 23:59. The year is held to 1970 on: Mojo::Date refuses an earlier instant,
# and Time::Local, under it, reads a year below 1000 as another one -- 0500
# as 2400. It captures the year, the fraction's digits and the offset.
const my $INSTANT_DAY => qr/([[:digit:]]{4}) (?: - [[:digit:]]{2} ){2}/amsx;
const my $INSTANT_TIME =>
  qr/[[:digit:]]{2} (?: : [[:digit:]]{2} ){2} (?: [.] ([[:digit:]]+) )?/amsx;
const my $INSTANT_OFFSET =>
  qr/([Zz] | [+-] (?: [01][[:digit:]] | 2[0-3] ) : [0-5][[:digit:]])/amsx;
const my $INSTANT_FILTER =>
  qr/\A $INSTANT_DAY [Tt ] $INSTANT_TIME (?: $INSTANT_OFFSET )? \z/amsx;

# Every search used to be a sequential scan of search_documents followed by a
# top-N sort, because none of the three match arms could use an index:
#
# - the tsquery took its configuration from me.language, a column of the same
#   row, and the planner only accepts an index clause whose other operand holds
#   no Var of the indexed relation -- so the GIN index on search_vector was out,
#   and the tsquery was re-parsed for every row;
# - the fuzzy match was similarity(...) >= ?, a function compared with a
#   number, which is not a pg_trgm operator and cannot use the trigram index;
# - a BitmapOr needs every arm of the OR indexable, so the one arm that was
#   (the LIKE) could not be used either.
#
# The configuration is now a bind parameter, DocumentBuilder's own, and the
# fuzzy arm is the % operator. Its threshold is the session setting
# pg_trgm.similarity_threshold, set on connect to the value this used to bind
# (see GPForum::Config). All three arms are indexable, so the planner can build
# a BitmapOr over the GIN and trigram indexes instead of reading every row.
const my $RANK_EXPRESSION => q{
    greatest(
        ts_rank_cd(
            me.search_vector,
            websearch_to_tsquery(?::regconfig, ?),
            32
        ),
        similarity(me.title_normalized, lower(?)) * 0.2
    )
};
const my $FTS_CONDITION =>
  q{me.search_vector @@ websearch_to_tsquery(?::regconfig, ?)};
const my $TRIGRAM_CONDITION => q{me.title_normalized % lower(?)};
const my $TITLE_CONTAINS_CONDITION =>
  q{me.title_normalized LIKE lower(?) ESCAPE '\'};

# ADR 0102 for a thread that moved. A document's category is its thread's at
# index time, and a move reindexes the thread's documents through the outbox,
# its posts a batch per message. Until each batch ran, search judged the
# documents by the category they had left: a thread moved from a public
# category into a private one stayed readable through search, to anyone. The
# permission condition reads category and space through me.category_id and
# me.space_id; requiring the first to be the thread's category now, and the
# second that category's space, makes the rule read the live ones. A document
# not yet reindexed is not shown at all, even where its new category would
# allow it, and comes back with its batch.
#
# Scalar subqueries, never a join: the planner cannot flatten one, so each is
# a primary-key lookup for each document examined, not a scan of posts or
# threads, and search keeps its two plans (search_resultset). The cost is two
# lookups per candidate, so the candidate cap bounds it, not the corpus: a
# word every document of postgres-search-plan.t's corpus holds -- 1,000
# candidates -- went from 4 to 6.4 ms on PostgreSQL 18; a rare word is
# unchanged. One subquery joining posts to threads was slower (8.2 ms).
const my $LIVE_CATEGORY => join q{ },
  q{(CASE me.entity_type},
  q{WHEN 'thread' THEN (SELECT live_thread.category_id},
  q{FROM threads live_thread WHERE live_thread.thread_id = me.entity_id)},
  q{WHEN 'post' THEN (SELECT live_thread.category_id},
  q{FROM threads live_thread WHERE live_thread.thread_id =},
  q{(SELECT live_post.thread_id FROM posts live_post},
  q{WHERE live_post.post_id = me.entity_id))},
  q{END)};

# How many candidates the ranked query was given, on every row it returns:
# the window runs over the joined candidates before the outer LIMIT, and the
# joins are one-to-one, so this is the count the inner LIMIT produced.
const my $CANDIDATE_COUNT => q{count(*) OVER ()};

# Transaction-local: it ends with the transaction search runs in, so the
# connection goes back to the statement_timeout every other query gets.
const my $SET_STATEMENT_TIMEOUT =>
  q{SELECT set_config('statement_timeout', ?, true)};

# How many of the newest matches are ranked (8.10). Ranking scores every
# candidate before the first page is known, so without a cap a word most
# documents hold -- "the", under the simple configuration -- was ranked over
# the whole corpus: 100 ms at 20,000 documents, linear beyond.
has candidate_limit   => $DEFAULT_CANDIDATES;
has permission_engine => undef;
has schema            => undef;

# Milliseconds. Zero or undef keeps the connection's own statement_timeout:
# zero there would switch the timeout off for search, not relax it.
has statement_timeout_ms => undef;

sub search ( $self, $actor, $query, $options ) {
    return $self->ranked_search( $actor, $query, $options )->{results};
}

# The results, and whether the ranking was capped: when every candidate slot
# was filled, older matches may exist that were never ranked, and the page
# says so rather than presenting the order as the best of all matches.
sub ranked_search ( $self, $actor, $query, $options ) {
    my $normalized = _normalized_query($query);
    my $rows       = $self->_timed_rows(
        sub { return $self->search_resultset( $actor, $query, $options ); } );
    my $candidates = @{$rows} ? _column( $rows->[0], 'candidate_count' ) : 0;

    return {
        candidate_limit => $self->candidate_limit,
        ranking_capped  =>
          ( ( $candidates || 0 ) >= $self->candidate_limit ? 1 : 0 ),
        results => [
            map  { _decorate_result( $_, $normalized ) }
            grep { $self->_can_render( $actor, $_ ) } @{$rows}
        ],
    };
}

# The resultset search() executes, before it is executed -- search_rs, not
# search, because DBIx::Class's search returns every row in list context and a
# caller passing this straight into a function call would get rows. Public so
# the plan the database chooses can be examined for the query the application
# actually sends: the query-plan gate EXPLAINed a hand-written copy of this,
# and the copy had none of the properties that made the real one a sequential
# scan.
#
# Two levels. The inner query finds the newest candidate_limit matches the
# actor may read, newest first, which idx_search_documents_created can serve
# by walking the table from the newest document and stopping at the limit --
# the plan for a word most documents hold. A rare word keeps the BitmapOr over
# the GIN and trigram indexes and sorts its few matches. The outer query ranks
# only those candidates, in the order search has always used. The planner
# picks the walk only with statistics on categories and spaces, which
# migration 048 has autovacuum gather.
sub search_resultset ( $self, $actor, $query, $options = undef ) {
    $options ||= {};

    my $limit      = _bounded_limit( $options->{limit} );
    my $normalized = _normalized_query($query);

    return $self->_candidates( $actor, $normalized, $options )
      ->as_subselect_rs->search_rs(
        undef,
        {
            join      => [qw(author category space)],
            '+select' => [
                _rank_expression($normalized), 'author.username',
                'author.display_name',         'category.visibility',
                'space.visibility',            \$CANDIDATE_COUNT,
            ],
            '+as' => [
                qw(rank_score author_username author_display_name
                  category_visibility space_visibility candidate_count)
            ],
            rows     => $limit,
            order_by => [
                { -desc => _rank_expression($normalized) },
                { -desc => 'me.source_created_at' },
                { -desc => 'me.indexed_at' },
                { -asc  => 'me.entity_type' },
                { -desc => 'me.entity_id' },
            ],
        }
      );
}

sub autocomplete ( $self, $actor, $prefix, $options ) {
    my $rows = $self->_timed_rows(
        sub {
            return $self->autocomplete_resultset( $actor, $prefix, $options );
        }
    );

    return [
        map  { _decorate_autocomplete_result($_) }
        grep { $self->_can_render( $actor, $_ ) } @{$rows}
    ];
}

# The resultset autocomplete executes.
# Public so the query-plan evidence EXPLAINs what actually runs.
sub autocomplete_resultset ( $self, $actor, $prefix, $options = undef ) {
    $options ||= {};

    my $limit      = _bounded_limit( $options->{limit} );
    my $normalized = _normalized_query($prefix);

    return $self->schema->resultset('SearchDocument')->search_rs(

        # Titles belong to threads. A post's document carries its thread's
        # title too, so without this a thread with fifty replies filled every
        # suggestion with the same title.
        {
            -and => [ $self->_permission_condition($actor), _live_scope() ],
            'me.entity_type'      => 'thread',
            'me.title_normalized' =>
              { -like => _like_pattern($normalized) . q{%} },
        },
        {
            join      => [qw(author category space)],
            '+select' => [
                'author.username',     'author.display_name',
                'category.visibility', 'space.visibility',
            ],
            '+as' => [
                qw(author_username author_display_name category_visibility
                  space_visibility)
            ],
            rows     => $limit,
            order_by => [
                'me.title_normalized',
                { -desc => 'me.source_created_at' },
                { -desc => 'me.entity_id' },
            ],
        }
    );
}

# The matches the actor may read, newest first, at most candidate_limit of
# them. Only category and space are joined: the permission condition reads
# their visibility, and the author is for display, joined by the outer query.
sub _candidates ( $self, $actor, $query, $options ) {
    return $self->schema->resultset('SearchDocument')->search_rs(
        _search_query( $self->_permission_condition($actor), $query, $options ),
        {
            join     => [qw(category space)],
            order_by => [
                { -desc => 'me.source_created_at' },
                { -desc => 'me.entity_id' },
            ],
            rows => $self->candidate_limit,
        }
    );
}

# The rows of the resultset $build returns, read under search's own
# statement_timeout. set_config(..., true) is SET LOCAL: it needs a transaction
# to be local to, and ends with it. A failure -- the timeout's own
# cancellation included -- rolls it back and is rethrown for the controller,
# which renders the page degraded instead of holding the worker.
sub _timed_rows ( $self, $build ) {
    my $timeout = $self->statement_timeout_ms;
    return [ _rows( $build->() ) ] if !$timeout;

    return $self->schema->txn_do(
        sub {
            $self->_set_statement_timeout($timeout);
            return [ _rows( $build->() ) ];
        }
    );
}

sub _set_statement_timeout ( $self, $timeout ) {
    my $storage = $self->schema->storage;
    return if !$storage->can('dbh_do');

    $storage->dbh_do(
        sub ( $, $dbh ) {
            return $dbh->do( $SET_STATEMENT_TIMEOUT, undef, $timeout );
        }
    );

    return;
}

# Anonymous callers keep the simple public predicate. Everyone else gets the
# engine's SQL form of the same rule can() applies per row, so the two cannot
# disagree about who may see what.
sub _permission_condition ( $self, $actor ) {
    if ( !$self->permission_engine ) {
        return { 'me.visibility' => 'public' };
    }

    # UNIVERSAL::can by name, not $engine->can(...): PermissionEngine defines
    # its own can($actor, $action, ...) for authorization, so the method-probe
    # spelling would call THAT with 'search_condition' as the actor. This is
    # the overridden-UNIVERSAL::can hazard recorded as 4.4 in
    # docs/QUALITY_PROGRAM.md, biting a caller.
    if ( !UNIVERSAL::can( $self->permission_engine, 'search_condition' ) ) {
        return { 'me.visibility' =>
              { -in => [ $self->_visibility_for( $actor, {} ) ] } };
    }

    return $self->permission_engine->search_condition($actor);
}

# The category and space the permission condition reads through
# me.category_id and me.space_id are the document's live ones ($LIVE_CATEGORY).
sub _live_scope {
    return (
        { 'me.category_id'    => { q{=}   => \$LIVE_CATEGORY } },
        { 'category.space_id' => { -ident => 'me.space_id' } },
    );
}

sub _visibility_for ( $self, $actor, $options ) {
    return $self->permission_engine->search_visibility_for( $actor, $options )
      if $self->permission_engine;

    return ('public');
}

sub _can_render ( $self, $actor, $row ) {
    return 1 if !$self->permission_engine;

    return $self->permission_engine->permits(
        $actor,
        'search.view',
        {
            entity_type         => _column( $row, 'entity_type' ),
            entity_id           => _column( $row, 'entity_id' ),
            visibility          => _column( $row, 'visibility' ),
            author_user_id      => _column( $row, 'author_user_id' ),
            category_id         => _column( $row, 'category_id' ),
            category_visibility => _column( $row, 'category_visibility' ),
            space_id            => _column( $row, 'space_id' ),
            space_visibility    => _column( $row, 'space_visibility' ),
        },
        {}
    );
}

sub _search_query ( $permission, $query, $options ) {

    # The permission predicate belongs in the WHERE clause, not in a grep after
    # the rows come back: the database applies LIMIT, so anything filtered
    # afterwards is a result the actor silently never receives.
    my $where = {
        -and => [ $permission, _live_scope() ],
        -or  => _match_clauses($query),
    };

    # A malformed filter is no filter: it can only narrow what the actor may
    # read, so dropping it widens nothing the permission condition allows.
    if ( _is_uuid( $options->{category_id} ) ) {
        $where->{'me.category_id'} = $options->{category_id};
    }
    if ( _is_uuid( $options->{author_user_id} ) ) {
        $where->{'me.author_user_id'} = $options->{author_user_id};
    }

    my @date_filters;
    for my $bound (qw(from to)) {
        my $bounds = _date_bounds( $options->{$bound} );
        next if !$bounds;

        push @date_filters, { 'me.source_created_at' => $bounds->{$bound} };
    }

    return $where if !@date_filters;

    return { -and => [ $where, @date_filters ] };
}

sub _is_uuid ($value) {
    return defined $value && $value =~ $UUID_FILTER ? 1 : 0;
}

# A date filter as the condition it makes a lower bound (from) and an upper
# one (to), both inclusive; undef when it is malformed. A day is what the
# form's date inputs send, and as an upper bound it covers the whole day: it
# was compared with the day's first instant, so to=<the day a reply was
# written> left the reply out. An RFC 3339 time is bound as _instant renders
# it, not as it was typed.
sub _date_bounds ($value) {
    my $undefined;
    return $undefined if !defined $value;

    if ( my ( $year, $month, $day ) = $value =~ $DAY_FILTER ) {
        my $start = _day_start( $year, $month, $day );
        return $undefined if !defined $start;

        return {
            from => { q{>=} => $value },
            to   => { q{<}  => _day_of( $start + $SECONDS_PER_DAY ) },
        };
    }

    my ( $instant_year, $fraction, $zone ) = $value =~ $INSTANT_FILTER;
    return $undefined if !defined $instant_year || $instant_year < $EPOCH_YEAR;

    # Parsed without its fraction, so the epoch is whole seconds (_instant).
    ( my $whole_seconds = $value ) =~ s/[.][[:digit:]]+//amsx;
    my $epoch = Mojo::Date->new($whole_seconds)->epoch;
    return $undefined if !defined $epoch;

    my $instant = _instant( $epoch, $fraction, $zone );

    return { from => { q{>=} => $instant }, to => { q{<=} => $instant } };
}

# A time as it is bound: its whole seconds as parsed, in UTC, then the
# fraction as typed (a zone moves a time by whole minutes, so it is still
# the instant's), cut to the microseconds a timestamp holds -- PostgreSQL
# refuses a fraction hundreds of digits long. Rendered from the parsed
# epoch, fraction and all, a float's fifteen digits bound .123456 as .12346
# and 10:00:59.9999999999 as 10:01:00. A time typed with no zone (Z or
# +hh:mm) is given none: PostgreSQL reads it in the session's time zone, as
# it reads a day and as it read the time before it was checked here; it had
# been bound as UTC. "Zone", not RFC 3339's word for it, which
# t/86-engineering-correctness.t reads as a paginated query after a search.
sub _instant ( $epoch, $fraction, $zone ) {
    my ( $seconds, $minutes, $hours, $day, $month, $year ) = gmtime $epoch;
    my $instant = sprintf '%04d-%02d-%02dT%02d:%02d:%02d',
      $year + $GMTIME_BASE_YEAR, $month + 1, $day, $hours, $minutes, $seconds;

    my $digits = substr $fraction // $EMPTY_TEXT, 0, $MICROSECOND_DIGITS;
    $digits =~ s/0+ \z//msx;
    if ( length $digits ) {
        $instant .= q{.} . $digits;
    }
    if ( defined $zone ) {
        $instant .= 'Z';
    }

    return $instant;
}

# The day's first second as an epoch, or undef for a day the calendar does
# not have -- timegm_modern dies on those. PostgreSQL has no year 0.
sub _day_start ( $year, $month, $day ) {
    my $undefined;
    return $undefined if $year < 1;

    return eval { timegm_modern( 0, 0, 0, $day, $month - 1, $year ) };
}

sub _day_of ($epoch) {
    my ( undef, undef, undef, $day, $month, $year ) = gmtime $epoch;

    return sprintf '%04d-%02d-%02d', $year + $GMTIME_BASE_YEAR, $month + 1,
      $day;
}

sub _match_clauses ($query) {
    return [
        \[
            $FTS_CONDITION,
            [ config => _search_config() ],
            [ query  => $query ]
        ],
        \[ $TRIGRAM_CONDITION, [ query => $query ] ],
        \[
            $TITLE_CONTAINS_CONDITION,
            [ query_pattern => q{%} . _like_pattern($query) . q{%} ],
        ],
    ];
}

sub _rank_expression ($query) {
    return \[
        $RANK_EXPRESSION,
        [ config => _search_config() ],
        [ query  => $query ],
        [ query  => $query ],
    ];
}

sub _search_config {
    return GPForum::Service::Search::DocumentBuilder->search_config;
}

sub _decorate_result ( $row, $query ) {
    my @terms   = _terms($query);
    my $snippet = _snippet_for( _column( $row, 'body' ), \@terms );

    return {
        entity_type          => _column( $row, 'entity_type' ),
        entity_id            => _column( $row, 'entity_id' ),
        category_id          => _column( $row, 'category_id' ),
        author_user_id       => _column( $row, 'author_user_id' ),
        author_username      => _column( $row, 'author_username' ),
        author_display_name  => _column( $row, 'author_display_name' ),
        author_profile_label =>
          _profile_label( _column( $row, 'author_username' ) ),
        title             => _column( $row, 'title' ),
        body              => _column( $row, 'body' ),
        snippet           => $snippet,
        snippet_html      => _snippet_html_for( $snippet, \@terms ),
        highlight_terms   => \@terms,
        visibility        => _column( $row, 'visibility' ),
        rank_score        => _column( $row, 'rank_score' ) || 0,
        source_created_at => _column( $row, 'source_created_at' ),
        indexed_at        => _column( $row, 'indexed_at' ),
    };
}

sub _decorate_autocomplete_result ($row) {
    return {
        entity_type          => _column( $row, 'entity_type' ),
        entity_id            => _column( $row, 'entity_id' ),
        category_id          => _column( $row, 'category_id' ),
        author_user_id       => _column( $row, 'author_user_id' ),
        author_username      => _column( $row, 'author_username' ),
        author_display_name  => _column( $row, 'author_display_name' ),
        author_profile_label =>
          _profile_label( _column( $row, 'author_username' ) ),
        title             => _column( $row, 'title' ),
        visibility        => _column( $row, 'visibility' ),
        source_created_at => _column( $row, 'source_created_at' ),
    };
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _bounded_limit ($limit) {
    return $DEFAULT_LIMIT
      if !defined $limit || $limit !~ /\A [[:digit:]]+ \z/msx || $limit < 1;

    return $MAX_LIMIT if $limit > $MAX_LIMIT;

    return $limit;
}

sub _normalized_query ($query) {
    $query = $EMPTY_TEXT if !defined $query;
    $query =~ s/\A \s+//msx;
    $query =~ s/\s+ \z//msx;
    $query =~ s/\s+/$SPACE/gmsx;

    return $query;
}

sub _like_pattern ($value) {
    $value = lc _normalized_query($value);
    $value =~ s/([\\%_])/\\$1/gmsx;

    return $value;
}

sub _terms ($query) {
    my %seen;
    return grep { !$seen{$_}++ }
      grep { length }
      map  { lc }
      split /[^[:alnum:]_]+/msx, $query;
}

sub _snippet_for ( $body, $terms ) {
    my $plain = _plain_text($body);
    return $EMPTY_TEXT if !length $plain;

    my $position = _first_match_position( lc $plain, $terms );
    $position = 0 if !defined $position;

    my $start   = $position > $SNIPPET_RADIUS ? $position - $SNIPPET_RADIUS : 0;
    my $snippet = substr $plain, $start, $SNIPPET_MAX_LENGTH;
    $snippet =~ s/\A \s+//msx;
    $snippet =~ s/\s+ \z//msx;

    $snippet = $ELLIPSIS . $snippet if $start > 0;
    $snippet .= $ELLIPSIS
      if $start + $SNIPPET_MAX_LENGTH < length $plain;

    return $snippet;
}

sub _plain_text ($body) {
    $body = $EMPTY_TEXT if !defined $body;
    $body =~ s/<[^>]*>/$SPACE/gmsx;
    $body = html_unescape($body);
    $body =~ s/\s+/$SPACE/gmsx;
    $body =~ s/\A \s+//msx;
    $body =~ s/\s+ \z//msx;

    return $body;
}

sub _first_match_position ( $plain, $terms ) {
    my $position;
    for my $term ( @{$terms} ) {
        my $candidate = index $plain, $term;
        next if $candidate < 0;
        $position = $candidate
          if !defined $position || $candidate < $position;
    }

    return $position;
}

sub _snippet_html_for ( $snippet, $terms ) {
    return xml_escape($snippet) if !@{$terms};

    my $pattern = join q{|}, map { quotemeta } @{$terms};
    return xml_escape($snippet) if !length $pattern;

    my @parts = split /($pattern)/imsx, $snippet;

    return join $EMPTY_TEXT, map {
        _is_highlight( $_, $terms )
          ? '<mark>' . xml_escape($_) . '</mark>'
          : xml_escape($_)
    } @parts;
}

sub _is_highlight ( $part, $terms ) {
    return if !defined $part || !length $part;

    my $folded = lc $part;
    for my $term ( @{$terms} ) {
        return 1 if $folded eq $term;
    }

    return;
}

sub _column ( $row, $name ) {
    return GPForum::Infrastructure::Row->column( $row, $name );
}

sub _profile_label ($username) {
    my $undefined;
    return $undefined if !defined $username || !length $username;

    return q{@} . $username;
}

1;

__END__

=head1 NAME

GPForum::Service::Search::Searcher - Full-text search and title autocomplete over the search documents.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $searcher = GPForum::Service::Search::Searcher->new(
        candidate_limit      => 1_000,
        permission_engine    => $permission_engine,
        schema               => $schema,
        statement_timeout_ms => 2_000,
    );
    my $page = $searcher->ranked_search( $actor, 'release notes',
        { limit => 20, category_id => $category_id } );
    for my $result ( @{ $page->{results} } ) {
        print $result->{title}, ': ', $result->{snippet}, "\n";
    }
    my $suggestions = $searcher->autocomplete( $actor, 'rel', { limit => 5 } );

=head1 DESCRIPTION

Searches C<search_documents>, the rows L<GPForum::Service::Search::Indexer>
keeps from L<GPForum::Service::Search::DocumentBuilder>. A document
matches a query when its search vector matches it as a web-search
C<tsquery>, when its normalized title is similar to it (the trigram C<%>
operator, under the session's C<pg_trgm.similarity_threshold> that
L<GPForum::Config> sets on connect), or when its title contains it. All
three arms can use an index, so the planner can combine the GIN and
trigram indexes instead of reading every row. The text-search
configuration is a bind parameter, the builder's own
(L<GPForum::Service::Search::DocumentBuilder/search_config>).

Only the newest C<candidate_limit> matches (default 1000) are ranked. An
inner query finds them, newest first, and an outer query ranks those by
the greater of the C<ts_rank_cd> score and a fifth of the title
similarity, then by age. Ranking is not done over the whole corpus: a word
most documents hold used to be ranked over every one of them. When every
candidate slot is filled, older matches may exist that were never ranked,
and C<ranked_search> says so.

What the actor may read is decided in the C<WHERE> clause, before
C<LIMIT>, so a page is not silently short. Without a C<permission_engine>
only C<public> documents are searched. With one, its C<search_condition>
is used (or, for an engine without one, the visibilities its
C<search_visibility_for> lists), and each returned row is checked again
with its C<permits> for C<search.view> before it is shown.

The category and space that rule reads are the document's live ones (ADR
0102): a document is searched only while its category is still its
thread's, looked up by primary key, and its space still that category's.
A document whose thread has moved is not found until the outbox has
indexed it again under the new category.

A filter is bound only when it is well formed: C<category_id> and
C<author_user_id> a UUID, C<from> and C<to> a day (C<YYYY-MM-DD>) or an
RFC 3339 time from 1970 on. Anything else is ignored, never sent to the
database. A time is bound to the microsecond, as typed; one given without
a zone (C<Z> or C<+hh:mm>) keeps none, so PostgreSQL reads it in the
session's time zone.

When C<statement_timeout_ms> is set and not zero, the query runs in a
transaction of its own with that C<statement_timeout> set locally, so the
connection goes back to its usual timeout afterwards. Zero or undef keeps
the connection's own timeout.

=head1 SUBROUTINES/METHODS

=head2 search

Takes an actor, a query string and a hash reference of options (or
undef), as for C<search_resultset>. Returns the C<results> array
reference of C<ranked_search>.

=head2 ranked_search

Takes the same arguments as C<search>. Returns a hash reference with
C<results>, C<candidate_limit> and C<ranking_capped> (1 when the
candidates filled the limit, so the order is the best of the newest
matches rather than of all of them). Each result is a hash reference with
C<entity_type>, C<entity_id>, C<category_id>, C<author_user_id>,
C<author_username>, C<author_display_name>, C<author_profile_label>
(C<@> and the username, or undef), C<title>, C<body>, C<visibility>,
C<rank_score>, C<source_created_at>, C<indexed_at>, C<highlight_terms>
(the query's distinct lower-cased words), C<snippet> (up to 220
characters of the body's plain text around the first matching word, with
C<...> where it was cut) and C<snippet_html> (the snippet HTML-escaped,
each matching word in C<< <mark> >>).

=head2 search_resultset

Takes an actor, a query string and an optional hash reference with
C<limit> (1 to 50, default 20; anything else is 20, and more than 50 is
50), C<category_id>, C<author_user_id>, and C<from> and C<to> (bounds on
C<source_created_at>, inclusive: a day given as C<to> includes the whole
day). Malformed filters are ignored (see L</DESCRIPTION>). Returns the
unexecuted resultset that
C<ranked_search> runs, with the author, category and space joined and
C<rank_score>, C<author_username>, C<author_display_name>,
C<category_visibility>, C<space_visibility> and C<candidate_count>
selected. The query is trimmed and its whitespace collapsed first. Public
so the query-plan evidence examines the query the application sends.

=head2 autocomplete

Takes an actor, a prefix and a hash reference of options (or undef), as
for C<autocomplete_resultset>. Returns an array reference of suggestions,
each a hash reference with C<entity_type>, C<entity_id>, C<category_id>,
C<author_user_id>, C<author_username>, C<author_display_name>,
C<author_profile_label>, C<title>, C<visibility> and
C<source_created_at>.

=head2 autocomplete_resultset

Takes an actor, a prefix and an optional hash reference with C<limit> (as
for C<search_resultset>). Returns the unexecuted resultset of the thread
documents the actor may read whose normalized title starts with the
prefix (lower-cased, its C<LIKE> wildcards escaped), ordered by title and
then newest first. Only threads are suggested: a post's document carries
its thread's title, and a thread with many replies used to fill every
suggestion with the same title.

=head1 DIAGNOSTICS

A database error is rethrown. Under C<statement_timeout_ms>, a query the
timeout cancels dies too, after its transaction is rolled back; the
search controller then renders the page degraded.

=head1 CONFIGURATION AND ENVIRONMENT

The application builds it from C<search_candidate_limit>
(C<GPFORUM_SEARCH_CANDIDATE_LIMIT>) and C<search_statement_timeout_ms>
(C<GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS>) in L<GPForum::Config>.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<Mojo::Date>, L<Mojo::Util>, L<Time::Local>,
L<GPForum::Infrastructure::Row>,
L<GPForum::Service::Search::DocumentBuilder>, PostgreSQL with C<pg_trgm>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A match older than the newest C<candidate_limit> is never ranked, however
well it would score; C<ranking_capped> reports when that may have
happened.

The documents of a thread that has moved are hidden from everyone, readers
of its new category included, until the outbox has indexed them again; a
large thread's posts come back a batch at a time.

A day, and a time given without a zone, are bounded in the session's
time zone, as PostgreSQL reads them compared with a C<timestamptz>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
