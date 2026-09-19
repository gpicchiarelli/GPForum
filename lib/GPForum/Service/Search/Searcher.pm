package GPForum::Service::Search::Searcher;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;
use Mojo::Util qw(html_unescape xml_escape);

our $VERSION = '0.001';

const my $DEFAULT_LIMIT      => 20;
const my $MAX_LIMIT          => 50;
const my $TRIGRAM_THRESHOLD  => 0.18;
const my $SNIPPET_RADIUS     => 80;
const my $SNIPPET_MAX_LENGTH => 220;
const my $EMPTY_TEXT         => q{};
const my $SPACE              => q{ };
const my $ELLIPSIS           => q{...};
const my $RANK_EXPRESSION => q{
    greatest(
        ts_rank_cd(
            me.search_vector,
            websearch_to_tsquery(me.language::regconfig, ?),
            32
        ),
        similarity(me.title_normalized, lower(?)) * 0.2
    )
};
const my $FTS_CONDITION =>
  q{me.search_vector @@ websearch_to_tsquery(me.language::regconfig, ?)};
const my $TRIGRAM_CONDITION =>
  q{similarity(me.title_normalized, lower(?)) >= ?};
const my $TITLE_CONTAINS_CONDITION =>
  q{me.title_normalized LIKE lower(?) ESCAPE '\'};

has permission_engine => undef;
has schema            => undef;

sub search {
    my ( $self, $actor, $query, $options ) = @_;

    $options ||= {};

    my @visibility = $self->_visibility_for( $actor, $options );
    my $limit      = _bounded_limit( $options->{limit} );
    my $normalized = _normalized_query($query);
    my $search     = $self->schema->resultset('SearchDocument')->search(
        _search_query( \@visibility, $normalized, $options ),
        {
            join      => 'author',
            '+select' => [
                _rank_expression($normalized), 'author.username',
                'author.display_name',
            ],
            '+as'    => [qw(rank_score author_username author_display_name)],
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

    return [
        map  { _decorate_result( $_, $normalized ) }
        grep { $self->_can_render( $actor, $_ ) } _rows($search)
    ];
}

sub autocomplete {
    my ( $self, $actor, $prefix, $options ) = @_;

    $options ||= {};

    my @visibility = $self->_visibility_for( $actor, $options );
    my $limit      = _bounded_limit( $options->{limit} );
    my $normalized = _normalized_query($prefix);
    my $search     = $self->schema->resultset('SearchDocument')->search(
        {
            'me.visibility'       => { -in => \@visibility },
            'me.permission_scope' => { -in => \@visibility },
            'me.title_normalized' =>
              { -like => _like_pattern($normalized) . q{%} },
        },
        {
            join      => 'author',
            '+select' => [ 'author.username', 'author.display_name' ],
            '+as'     => [qw(author_username author_display_name)],
            rows      => $limit,
            order_by  => [
                'me.title_normalized',
                { -desc => 'me.source_created_at' },
                { -desc => 'me.entity_id' },
            ],
        }
    );

    return [
        map  { _decorate_autocomplete_result($_) }
        grep { $self->_can_render( $actor, $_ ) } _rows($search)
    ];
}

sub _visibility_for {
    my ( $self, $actor, $options ) = @_;

    return $self->permission_engine->search_visibility_for( $actor, $options )
      if $self->permission_engine;

    return ('public');
}

sub _can_render {
    my ( $self, $actor, $row ) = @_;

    return 1 if !$self->permission_engine;

    return $self->permission_engine->can(
        $actor,
        'search.view',
        {
            entity_type    => _column( $row, 'entity_type' ),
            entity_id      => _column( $row, 'entity_id' ),
            visibility     => _column( $row, 'visibility' ),
            author_user_id => _column( $row, 'author_user_id' ),
            category_id    => _column( $row, 'category_id' ),
        },
        {}
    );
}

sub _search_query {
    my ( $visibility, $query, $options ) = @_;

    my $where = {
        'me.visibility'       => { -in => $visibility },
        'me.permission_scope' => { -in => $visibility },
        -or                   => _match_clauses($query),
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

sub _match_clauses {
    my ($query) = @_;

    return [
        \[ $FTS_CONDITION, [ query => $query ] ],
        \[
            $TRIGRAM_CONDITION,
            [ query     => $query ],
            [ threshold => $TRIGRAM_THRESHOLD ],
        ],
        \[
            $TITLE_CONTAINS_CONDITION,
            [ query_pattern => q{%} . _like_pattern($query) . q{%} ],
        ],
    ];
}

sub _rank_expression {
    my ($query) = @_;

    return \[ $RANK_EXPRESSION, [ query => $query ], [ query => $query ], ];
}

sub _decorate_result {
    my ( $row, $query ) = @_;

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

sub _decorate_autocomplete_result {
    my ($row) = @_;

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

sub _rows {
    my ($search) = @_;

    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

sub _bounded_limit {
    my ($limit) = @_;

    return $DEFAULT_LIMIT
      if !defined $limit || $limit !~ /\A [[:digit:]]+ \z/msx || $limit < 1;

    return $MAX_LIMIT if $limit > $MAX_LIMIT;

    return $limit;
}

sub _normalized_query {
    my ($query) = @_;

    $query = $EMPTY_TEXT if !defined $query;
    $query =~ s/\A \s+//msx;
    $query =~ s/\s+ \z//msx;
    $query =~ s/\s+/$SPACE/gmsx;

    return $query;
}

sub _defined_non_empty {
    my ($value) = @_;

    return defined $value && length $value ? 1 : 0;
}

sub _like_pattern {
    my ($value) = @_;

    $value = lc _normalized_query($value);
    $value =~ s/([\\%_])/\\$1/gmsx;

    return $value;
}

sub _terms {
    my ($query) = @_;

    my %seen;
    return grep { !$seen{$_}++ }
      grep { length }
      map  { lc }
      split /[^[:alnum:]_]+/msx, $query;
}

sub _snippet_for {
    my ( $body, $terms ) = @_;

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

sub _plain_text {
    my ($body) = @_;

    $body = $EMPTY_TEXT if !defined $body;
    $body =~ s/<[^>]*>/$SPACE/gmsx;
    $body = html_unescape($body);
    $body =~ s/\s+/$SPACE/gmsx;
    $body =~ s/\A \s+//msx;
    $body =~ s/\s+ \z//msx;

    return $body;
}

sub _first_match_position {
    my ( $plain, $terms ) = @_;

    my $position;
    for my $term ( @{$terms} ) {
        my $candidate = index $plain, $term;
        next if $candidate < 0;
        $position = $candidate
          if !defined $position || $candidate < $position;
    }

    return $position;
}

sub _snippet_html_for {
    my ( $snippet, $terms ) = @_;

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

sub _is_highlight {
    my ( $part, $terms ) = @_;

    return if !defined $part || !length $part;

    my $folded = lc $part;
    for my $term ( @{$terms} ) {
        return 1 if $folded eq $term;
    }

    return;
}

sub _column {
    my ( $row, $name ) = @_;

    return $row->{$name}           if ref $row eq 'HASH';
    return $row->get_column($name) if $row && $row->can('get_column');

    my $undefined;
    return $undefined;
}

sub _profile_label {
    my ($username) = @_;

    my $undefined;
    return $undefined if !defined $username || !length $username;

    return q{@} . $username;
}

1;
