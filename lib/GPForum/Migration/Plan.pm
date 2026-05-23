package GPForum::Migration::Plan;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;
use Mojo::File qw(path);

our $VERSION = '0.001';

has directory => sub { return path('migrations'); };

sub files {
    my ($self) = @_;

    my $directory = path( $self->directory );

    croak "migration directory not found: $directory"
      if !-d $directory->to_string;

    return [
        sort map { $_->to_string }
          grep { $_->basename =~ /\A [[:digit:]]+ [_] .+ [.] sql \z/msx }
          @{ $directory->list->to_array }
    ];
}

sub summary {
    my ($self) = @_;

    my @summary;

    for my $migration_file ( @{ $self->files } ) {
        my $file = path($migration_file);
        push @summary,
          {
            file        => $file->to_string,
            version     => _version_from_file($file),
            description => _description_from_file($file),
          };
    }

    return \@summary;
}

sub _version_from_file {
    my ($file) = @_;

    my ($version) = $file->basename =~ /\A ( [[:digit:]]+ ) [_] /msx;

    return $version;
}

sub _description_from_file {
    my ($file) = @_;

    my $description = $file->basename;
    $description =~ s/\A [[:digit:]]+ [_]//msx;
    $description =~ s/[.] sql \z//msx;
    $description =~ s/[_]/ /gmsx;

    return $description;
}

1;

__END__

=head1 NAME

GPForum::Migration::Plan - Migration file discovery.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $summary = GPForum::Migration::Plan->new->summary;

=head1 DESCRIPTION

Discovers ordered SQL migration files for the GPForum PostgreSQL migration
framework.

=head1 SUBROUTINES/METHODS

=head2 files

Returns sorted migration file paths.

=head2 summary

Returns version, description, and file metadata for migrations.

=head1 DIAGNOSTICS

Throws exceptions when the migration directory is missing.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<Carp>, L<Mojo::Base>, and L<Mojo::File>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

This milestone plans migrations but does not yet apply them to a live database.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
