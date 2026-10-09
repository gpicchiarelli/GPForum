# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::I18N::CliCatalog;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);

use GPForum::Config::Report;
use GPForum::Service::I18N::PoFile;

our $VERSION = '0.001';

const my $ENGLISH => 'en';
const my $ITALIAN => 'it';

# The variables that name the language of messages, strongest first, as
# POSIX reads them: LC_ALL overrides LC_MESSAGES, which overrides LANG.
const my @LANGUAGE_VARIABLES => qw(LC_ALL LC_MESSAGES LANG);

# This module is lib/GPForum/Service/I18N/CliCatalog.pm in the checkout, four
# directories below the root that holds locale/cli/. Resolved while the module
# loads, so a later chdir cannot move it. The forum's own catalogs are the
# locale/*.po beside it: the command line keeps its words apart from the
# pages'.
const my $CHECKOUT_DEPTH => 4;
const my $CLI_DIRECTORY  => _cli_directory_of(__FILE__);

# Read once, when the module loads.
my $CATALOGS = __PACKAGE__->load_catalogs($CLI_DIRECTORY);

has language => sub { return __PACKAGE__->language_of( \%ENV ); };

# Italian for it, it_IT.UTF-8 and the like; English for anything else,
# including C and POSIX. The first of the variables that is set decides, as it
# does for every other program.
sub language_of ( $class, $environment ) {
    for my $variable (@LANGUAGE_VARIABLES) {
        my $value = $environment->{$variable};
        next if !defined $value || !length $value;

        return $value =~ /\A it (?: [_.@-] | \z )/msxi ? $ITALIAN : $ENGLISH;
    }

    return $ENGLISH;
}

sub load_catalogs ( $class, $directory ) {
    my %catalogs;
    for my $file ( path($directory)->list->grep(qr/[.]po\z/msx)->each ) {
        my $document = GPForum::Service::I18N::PoFile->read_file($file);
        $catalogs{ $file->basename('.po') } = {
            map  { $_->{context} => $_->{strings}[0] }
            grep { defined $_->{context} && length $_->{strings}[0] }
              @{ $document->{entries} }
        };
    }

    return \%catalogs;
}

sub catalogs ($class) {
    return { map { $_ => { %{ $CATALOGS->{$_} } } } keys %{$CATALOGS} };
}

# The template for a key in this catalog's language, else in English, else
# undef.
sub template ( $self, $key ) {
    return $CATALOGS->{ $self->language }{$key} // $CATALOGS->{$ENGLISH}{$key};
}

sub text ( $self, $key, $parameters = {} ) {
    return GPForum::Config::Report->text( $key, $parameters,
        $self->translator );
}

sub translator ($self) {
    return sub ($key) { return $self->template($key); };
}

# The configuration's problems as the operator reads them, in their
# language.
sub config_report ( $self, $problems ) {
    return GPForum::Config::Report->render( $problems, $self->translator );
}

sub _cli_directory_of ($file) {
    my $directory = path($file)->to_abs->dirname;
    for ( 1 .. $CHECKOUT_DEPTH ) {
        $directory = $directory->dirname;
    }

    return $directory->child( 'locale', 'cli' )->to_string;
}

1;

__END__

=head1 NAME

GPForum::Service::I18N::CliCatalog - The command line's words, in the
operator's language.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $catalog = GPForum::Service::I18N::CliCatalog->new;
    say $catalog->text( 'config.required',
        { variable => 'GPFORUM_DATABASE_DSN' } );
    print {*STDERR} $catalog->config_report( $error->problems );

=head1 DESCRIPTION

What GPForum says to an operator -- at the command line, at start-up, in the
log -- follows the language the operator's environment asks for, as the
forum follows a member's: Italian when C<LC_ALL>, C<LC_MESSAGES> or C<LANG>
(the first one set) starts with C<it>, English otherwise. The words are GNU
gettext catalogs in C<locale/cli/>, one per language, read with
L<GPForum::Service::I18N::PoFile>: each entry's msgctxt is the key the code
asks for, its msgid the English and its msgstr the translation. They are
apart from the forum's own catalogs in C<locale/>, which the pages read.

=head1 SUBROUTINES/METHODS

=head2 language_of

Class method. Takes an environment hash reference and returns C<it> or
C<en>.

=head2 load_catalogs

Class method. Takes a directory and returns each C<LANG.po> in it as
C<< { LANG => { key => template } } >>, leaving out entries without a
translation.

=head2 catalogs

Class method. A copy of the catalogs read from C<locale/cli/> when the module
loaded.

=head2 language

The language this catalog speaks: C<it> or C<en>, from C<%ENV> unless it is
given.

=head2 template

Takes a key and returns its template in this catalog's language, falling
back to English, or undef for a key neither knows.

=head2 text

Takes a key and an optional hash reference of placeholder values and
returns the text with each C<{name}> filled in.

=head2 translator

A code reference that turns a key into its template, for
L<GPForum::Config::Report/render>.

=head2 config_report

Takes the problems a L<GPForum::X::Config> carries and returns the report
in this catalog's language.

=head1 DIAGNOSTICS

A catalog that does not parse throws L<GPForum::X::Config> from
L<GPForum::Service::I18N::PoFile> when the module loads.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<LC_ALL>, C<LC_MESSAGES> and C<LANG>, and the catalogs in
C<locale/cli/>.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<Mojo::File>, L<GPForum::Config::Report>,
L<GPForum::Service::I18N::PoFile>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Two languages, as the forum ships. A catalog for another language is read
but never chosen until L</language_of> learns its code.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
