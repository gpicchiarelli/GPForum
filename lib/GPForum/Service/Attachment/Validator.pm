# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Attachment::Validator;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

const my $MAX_BYTES          => 25 * 1_024 * 1_024;
const my $TEXT_SAMPLE_LENGTH => 512;

my %ALLOWED_MEDIA = map { $_ => 1 } qw(
  image/gif
  image/jpeg
  image/png
  image/webp
  application/pdf
  text/plain
);

# The largest upload accepted, so a scanner can be checked against it.
sub max_bytes ($class) {
    return $MAX_BYTES;
}

sub validate_upload ( $self, $input ) {
    my %errors;
    my $media_type = _server_media_type($input);

    _require_text( \%errors, $input, 'owner_user_id' );
    _require_text( \%errors, $input, 'original_filename' );
    _require_text( \%errors, { media_type => $media_type }, 'media_type' );
    _require_text( \%errors, $input,                        'checksum' );
    _validate_size( \%errors, $input->{byte_size} );
    _validate_media_type( \%errors, $media_type );
    _validate_filename( \%errors, $input->{original_filename} );

    return { ok => 0, errors => \%errors } if keys %errors;

    return { ok => 1, values => _normalized( $input, $media_type ) };
}

sub sniff_media_type ( $self, $content ) {
    my $undefined;
    return $undefined   if !defined $content;
    return 'image/png'  if $content =~ /\A \x89 PNG \x0d \x0a \x1a \x0a/msx;
    return 'image/jpeg' if $content =~ /\A \xff \xd8 \xff/msx;
    return 'image/gif'  if $content =~ /\A GIF (?: 87a | 89a )/msx;
    return 'application/pdf' if $content =~ /\A %PDF-/msx;
    return 'image/webp'
      if length $content >= 12
      && substr( $content, 0, 4 ) eq 'RIFF'
      && substr( $content, 8, 4 ) eq 'WEBP';

    return 'text/plain' if _looks_like_text($content);

    return 'application/octet-stream';
}

sub _require_text ( $errors, $input, $field ) {
    if ( !defined $input->{$field} || !length $input->{$field} ) {
        $errors->{$field} = "$field is required";
    }

    return;
}

sub _validate_size ( $errors, $byte_size ) {
    if ( !defined $byte_size || $byte_size <= 0 ) {
        $errors->{byte_size} = 'byte_size is required';
        return;
    }

    if ( $byte_size > $MAX_BYTES ) {
        $errors->{byte_size} = 'byte_size exceeds limit';
    }

    return;
}

sub _validate_media_type ( $errors, $media_type ) {
    return if !defined $media_type || !length $media_type;

    if ( !$ALLOWED_MEDIA{ lc $media_type } ) {
        $errors->{media_type} = 'media_type is not allowed';
    }

    return;
}

sub _validate_filename ( $errors, $filename ) {
    return if !defined $filename || !length $filename;

    if ( $filename =~ /[.] (?: cgi | exe | pl | pm | php | sh ) \z/imsx ) {
        $errors->{original_filename} = 'executable uploads are not allowed';
    }

    return;
}

sub _server_media_type ($input) {
    return $input->{sniffed_media_type}
      if defined $input->{sniffed_media_type}
      && length $input->{sniffed_media_type};
    return GPForum::Service::Attachment::Validator->new->sniff_media_type(
        $input->{content} )
      if defined $input->{content};

    return $input->{media_type};
}

sub _looks_like_text ($content) {
    my $sample = substr $content, 0, $TEXT_SAMPLE_LENGTH;
    return if $sample =~ /[\x00-\x08\x0b\x0c\x0e-\x1f]/msx;

    return 1;
}

sub _normalized ( $input, $media_type ) {
    return {
        owner_user_id     => $input->{owner_user_id},
        original_filename => $input->{original_filename},
        media_type        => lc $media_type,
        byte_size         => int $input->{byte_size},
        checksum          => lc $input->{checksum},
    };
}

1;

__END__

=head1 NAME

GPForum::Service::Attachment::Validator - Check an upload's metadata and tell its media type from its bytes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $validator = GPForum::Service::Attachment::Validator->new;

    my $result = $validator->validate_upload(
        {
            byte_size         => length $content,
            checksum          => $sha256_hex,
            content           => $content,
            original_filename => 'diagram.png',
            owner_user_id     => $user_id,
        }
    );
    return $result->{errors} if !$result->{ok};
    my $values = $result->{values};

    my $limit = GPForum::Service::Attachment::Validator->max_bytes;

=head1 DESCRIPTION

The first check an upload passes. The media type is decided on the server:
a C<sniffed_media_type> given by the caller wins, then the type sniffed from
C<content>, and only without either the client's C<media_type>. That type
must be C<image/gif>, C<image/jpeg>, C<image/png>, C<image/webp>,
C<application/pdf> or C<text/plain>; the size must be positive and at most
25 MiB; and a filename ending in C<.cgi>, C<.exe>, C<.pl>, C<.pm>, C<.php>
or C<.sh> is refused whatever its type.

Sniffing reads the magic numbers of PNG, JPEG, GIF, PDF and WebP. Other
content is C<text/plain> when its first 512 bytes hold no control character
other than tab, line feed and carriage return, and
C<application/octet-stream> otherwise.

=head1 SUBROUTINES/METHODS

=head2 max_bytes

Class method. Returns the largest upload accepted, in bytes (25 MiB), so a
scanner's own limit can be checked against it.

=head2 validate_upload

Takes a hash reference with C<owner_user_id>, C<original_filename>,
C<checksum>, C<byte_size>, and C<media_type>, C<content> or
C<sniffed_media_type>. Returns C<< { ok => 0, errors => \%errors } >> with
every problem found, keyed by field, or
C<< { ok => 1, values => \%values } >> where the values are
C<owner_user_id>, C<original_filename>, C<media_type> and C<checksum>
(both lower-cased) and C<byte_size> (an integer).

=head2 sniff_media_type

Takes the uploaded bytes. Returns the media type they show,
C<application/octet-stream> when none is recognized, or undef for undef
content.

=head1 DIAGNOSTICS

Nothing is thrown. The errors C<validate_upload> returns are
C<FIELD is required> for C<owner_user_id>, C<original_filename>,
C<media_type> and C<checksum>; C<byte_size is required> or
C<byte_size exceeds limit>; C<media_type is not allowed>; and
C<executable uploads are not allowed> for C<original_filename>.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

None beyond L<Mojo::Base> and L<Const::Fast>.

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
