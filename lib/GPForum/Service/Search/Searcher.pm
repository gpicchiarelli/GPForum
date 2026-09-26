# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Search::Searcher;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Row;
use GPForum::Service::Search::DocumentBuilder;
use Mojo::Util qw(html_unescape xml_escape);

our $VERSION = '0.001';

const my $DEFAULT_LIMIT      => 20;
const my $MAX_LIMIT          => 50;
const my $SNIPPET_RADIUS     => 80;
const my $SNIPPET_MAX_LENGTH => 220;
const my $EMPTY_TEXT         => q{};
const my $SPACE              => q{ };
const my $ELLIPSIS           => q{...};

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

has permission_engine => undef;
has schema            => undef;

sub search ( $self, $actor, $query, $options ) {
    my $normalized = _normalized_query($query);
    my $search     = $self->search_resultset( $actor, $query, $options );

    return [
        map  { _decorate_result( $_, $normalized ) }
        grep { $self->_can_render( $actor, $_ ) } _rows($search)
    ];
}

# The resultset search() executes, before it is executed -- search_rs, not
# search, because DBIx::Class's search returns every row in list context and a
# caller passing this straight into a function call would get rows. Public so
# the plan
# the database chooses can be examined for the query the application actually
# sends: the query-plan gate EXPLAINed a hand-written copy of this, and the
# copy had none of the properties that made the real one a sequential scan.
sub search_resultset ( $self, $actor, $query, $options = undef ) {
    $options ||= {};

    my $limit      = _bounded_limit( $options->{limit} );
    my $normalized = _normalized_query($query);

    return $self->schema->resultset('SearchDocument')->search_rs(
        _search_query(
            $self->_permission_condition($actor),
            $normalized, $options
        ),
        {
            join      => [qw(author category space)],
            '+select' => [
                _rank_expression($normalized), 'author.username',
                'author.display_name',         'category.visibility',
                'space.visibility',
            ],
            '+as' => [
                qw(rank_score author_username author_display_name
                  category_visibility space_visibility)
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
    return [
        map  { _decorate_autocomplete_result($_) }
        grep { $self->_can_render( $actor, $_ ) }
          _rows( $self->autocomplete_resultset( $actor, $prefix, $options ) )
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
            -and                  => [ $self->_permission_condition($actor) ],
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
        -and => [$permission],
        -or  => _match_clauses($query),
    };

    $where->{'me.category_id'} = $options->{category_id}
      if _defined_non_empty( $options->{category_id} );
    $where->{'me.author_user_id'} = $options->{author_user_id}
      if _defined_non_empty( $options->{author_user_id} );

    my @date_filters;
    push @date_filters,
      { 'me.source_created_at' => { '>=' => $options->{from} } }
      if _defined_non_empty( $options->{from} );
    push @date_filters, { 'me.source_created_at' => { '<=' => $options->{to} } }
      if _defined_non_empty( $options->{to} );

    return $where if !@date_filters;

    return { -and => [ $where, @date_filters ] };
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

sub _defined_non_empty ($value) {
    return defined $value && length $value ? 1 : 0;
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
