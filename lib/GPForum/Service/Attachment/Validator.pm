package GPForum::Service::Attachment::Validator;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;

our $VERSION = '0.001';

const my $MAX_BYTES => 25 * 1_024 * 1_024;

my %ALLOWED_MEDIA = map { $_ => 1 } qw(
  image/gif
  image/jpeg
  image/png
  image/webp
  application/pdf
  text/plain
);

sub validate_upload {
    my ( $self, $input ) = @_;

    my %errors;

    _require_text( \%errors, $input, 'owner_user_id' );
    _require_text( \%errors, $input, 'original_filename' );
    _require_text( \%errors, $input, 'media_type' );
    _require_text( \%errors, $input, 'checksum' );
    _validate_size( \%errors, $input->{byte_size} );
    _validate_media_type( \%errors, $input->{media_type} );
    _validate_filename( \%errors, $input->{original_filename} );

    return { ok => 0, errors => \%errors } if keys %errors;

    return { ok => 1, values => _normalized($input) };
}

sub _require_text {
    my ( $errors, $input, $field ) = @_;

    if ( !defined $input->{$field} || !length $input->{$field} ) {
        $errors->{$field} = "$field is required";
    }

    return;
}

sub _validate_size {
    my ( $errors, $byte_size ) = @_;

    if ( !defined $byte_size || $byte_size <= 0 ) {
        $errors->{byte_size} = 'byte_size is required';
        return;
    }

    if ( $byte_size > $MAX_BYTES ) {
        $errors->{byte_size} = 'byte_size exceeds limit';
    }

    return;
}

sub _validate_media_type {
    my ( $errors, $media_type ) = @_;

    return if !defined $media_type || !length $media_type;

    if ( !$ALLOWED_MEDIA{ lc $media_type } ) {
        $errors->{media_type} = 'media_type is not allowed';
    }

    return;
}

sub _validate_filename {
    my ( $errors, $filename ) = @_;

    return if !defined $filename || !length $filename;

    if ( $filename =~ /[.] (?: cgi | exe | pl | pm | php | sh ) \z/imsx ) {
        $errors->{original_filename} = 'executable uploads are not allowed';
    }

    return;
}

sub _normalized {
    my ($input) = @_;

    return {
        owner_user_id     => $input->{owner_user_id},
        original_filename => $input->{original_filename},
        media_type        => lc $input->{media_type},
        byte_size         => int $input->{byte_size},
        checksum          => lc $input->{checksum},
    };
}

1;
