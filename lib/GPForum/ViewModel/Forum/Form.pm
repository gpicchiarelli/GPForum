package GPForum::ViewModel::Forum::Form;

use strict;
use warnings;

use Const::Fast;
use GPForum::ViewModel::Forum::Rows;
use Mojo::Base 'GPForum::ViewModel::Base';

our $VERSION = '0.001';

const my $BODY_ROWS          => 10;
const my $DEFAULT_VISIBILITY => 'public';
const my $ERROR_SUMMARY_ID   => 'thread-error-summary';
const my $HEADING_ID         => 'new-thread-heading';

has rows => sub { return GPForum::ViewModel::Forum::Rows->new; };

sub new_thread_form {
    my ( $self, %input ) = @_;

    my $state  = $self->_form_state( \%input );
    my $fields = $self->form_fields(
        errors => $state->{errors},
        specs  => $self->_field_specs,
        values => $state->{form_values},
    );

    return $self->_form_payload( \%input, $state, $fields );
}

sub _form_state {
    my ( $self, $input ) = @_;

    my $errors               = $self->rows->hash_or_empty( $input->{errors} );
    my $values               = $self->rows->hash_or_empty( $input->{values} );
    my $selected_category_id = $self->_selected_category_id( $input, $values );

    return {
        errors      => $errors,
        form_values => {
            %{$values},
            category_id => $selected_category_id,
            command_id  => $self->_command_id( $input, $values ),
            visibility  => $self->_visibility($values),
        },
        selected_category_id => $selected_category_id,
        values               => $values,
    };
}

sub _form_payload {
    my ( $self, $input, $state, $fields ) = @_;

    return {
        categories           => $self->_categories($input),
        command_id           => $state->{form_values}{command_id},
        csrf_token           => $input->{csrf_token},
        error_fields         => $self->form_error_fields($fields),
        errors               => $state->{errors},
        fields               => [qw(category_id title body_source visibility)],
        form_fields          => $fields,
        selected_category_id => $state->{selected_category_id},
        ui                   => $self->_form_ui( $state->{errors} ),
        values               => $state->{values},
    };
}

sub _categories {
    my ( $self, $input ) = @_;

    my $categories = $self->rows->array_or_empty( $input->{categories} );

    return [ map { $self->rows->category($_) } @{$categories} ];
}

sub _form_ui {
    my ( $self, $errors ) = @_;

    return {
        described_by => $self->form_described_by(
            errors     => $errors,
            summary_id => $ERROR_SUMMARY_ID,
        ),
        heading_id => $HEADING_ID,
        summary_id => $ERROR_SUMMARY_ID,
    };
}

sub _selected_category_id {
    my ( $self, $input, $values ) = @_;

    if ( $self->rows->has_text( $input->{selected_category_id} ) ) {
        return $input->{selected_category_id};
    }
    if ( $self->rows->has_text( $values->{category_id} ) ) {
        return $values->{category_id};
    }

    return q{};
}

sub _command_id {
    my ( $self, $input, $values ) = @_;

    if ( $self->rows->has_text( $input->{command_id} ) ) {
        return $input->{command_id};
    }
    if ( $self->rows->has_text( $values->{command_id} ) ) {
        return $values->{command_id};
    }

    return q{};
}

sub _visibility {
    my ( $self, $values ) = @_;

    if ( $self->rows->has_text( $values->{visibility} ) ) {
        return $values->{visibility};
    }

    return $DEFAULT_VISIBILITY;
}

sub _field_specs {
    return [
        {
            id        => 'thread-category',
            label_key => 'search.category',
            name      => 'category_id',
            type      => 'select',
        },
        {
            id        => 'thread-title',
            label_key => 'forum.thread_title',
            name      => 'title',
            required  => 1,
            type      => 'text',
        },
        {
            id        => 'thread-body',
            label_key => 'forum.thread_body',
            name      => 'body_source',
            required  => 1,
            rows      => $BODY_ROWS,
            type      => 'textarea',
        },
        {
            id        => 'thread-visibility',
            label_key => 'forum.visibility',
            name      => 'visibility',
            type      => 'select',
        },
    ];
}

1;

__END__

=head1 NAME

GPForum::ViewModel::Forum::Form - New-thread form view model.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $form = $forms->new_thread_form(%input);

=head1 DESCRIPTION

Owns new-thread field descriptors, default visibility, command-id selection,
and error-summary wiring. Category row shaping stays on
L<GPForum::ViewModel::Forum::Rows>.
L<GPForum::ViewModel::Forum::Presenter> remains the public facade.

=head1 SUBROUTINES/METHODS

=head2 new_thread_form

Returns the new-thread SSR and JSON-compatible form payload.

=head1 DIAGNOSTICS

Missing values become empty strings. Visibility defaults to public.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<GPForum::ViewModel::Base> form helpers.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

JSON C<fields> names stay fixed for compatibility.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
