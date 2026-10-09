# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Base;

use Mojo::Base -base, -signatures;
use v5.40;

use mro;

use GPForum::X::Argument;

our $VERSION = '0.001';

# The attributes each class declared with requires, in declaration order,
# keyed by the class that declared them. A subclass inherits its parents'
# through the method resolution order, not by copying them here.
my %REQUIRED;

sub requires ( $class, @names ) {
    if ( ref $class ) {
        GPForum::X::Argument->throw(
            message => 'requires is a class method, called on ' . ref $class );
    }
    for my $name (@names) {
        if ( !defined $name || !length $name ) {
            GPForum::X::Argument->throw(
                message => "$class requires an attribute name" );
        }
        $class->attr($name);
        push @{ $REQUIRED{$class} }, $name;
    }

    return $class;
}

# Every attribute a new object of this class must be given: its ancestors'
# first, each name once.
sub required_attributes ($invocant) {
    my $class = ref $invocant || $invocant;
    my %seen;
    my @names = grep { !$seen{$_}++ }
      map { @{ $REQUIRED{$_} // [] } }
      reverse @{ mro::get_linear_isa($class) };

    return @names;
}

sub new ( $class, @arguments ) {
    my $self    = $class->SUPER::new(@arguments);
    my @missing = grep { !defined $self->{$_} } $self->required_attributes;
    if (@missing) {
        my ( undef, $file, $line ) = caller;
        GPForum::X::Argument->throw(
            message  => ( ref $self ) . ' requires ' . join( q{, }, @missing ),
            location => "$file line $line",
        );
    }

    return $self;
}

1;

__END__

=head1 NAME

GPForum::Base - A Mojo::Base class whose required attributes are declared.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    package GPForum::Service::Example::Store;

    use Mojo::Base 'GPForum::Base', -signatures;
    use v5.40;

    __PACKAGE__->requires(qw(schema recorder));

    has clock => sub { GPForum::Infrastructure::Clock->new };

    # Elsewhere:
    GPForum::Service::Example::Store->new( schema => $schema );
    # throws GPForum::X::Argument:
    # "GPForum::Service::Example::Store requires recorder"

    GPForum::Service::Example::Store->required_attributes;
    # ('schema', 'recorder')

=head1 DESCRIPTION

C<has NAME =E<gt> undef> says nothing about whether a class can work without
the attribute, and a store built without its schema fails only when a method
first dereferences it, far from the line that forgot it. A class that extends
GPForum::Base declares the attributes it cannot work without, and C<new>
refuses to build an object that lacks one. ADR 0118 records the rule.

A required attribute has no default. Every other attribute is declared with
C<has> as before, and a lazy default is still built on first read, not by
C<new>.

=head1 SUBROUTINES/METHODS

=head2 requires

Class method. Declares each name as an accessor with no default and records
it as required for the class and every subclass. Returns the class.

=head2 required_attributes

Class or instance method. The names a new object must be given, inherited
ones first, each once, in declaration order.

=head2 new

Builds the object from a list of pairs or a hash reference, as
L<Mojo::Base/new> does, then throws L<GPForum::X::Argument> naming the class
and every required attribute that is missing or undef. A false but defined
value, such as C<0> or the empty string, is given.

=head1 DIAGNOSTICS

=over 4

=item C<CLASS requires NAME, ...>

An L<GPForum::X::Argument> from C<new>: the listed required attributes were
not passed or were undef. Its C<location> is the line that called C<new>.

=item C<CLASS requires an attribute name>

C<requires> was given an undefined or empty name.

=item C<requires is a class method, called on CLASS>

C<requires> was called on an object.

=back

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>, L<mro>, L<GPForum::X::Argument>.

=head1 INCOMPATIBILITIES

A subclass that overrides C<new> must call C<SUPER::new>, or nothing is
checked.

=head1 BUGS AND LIMITATIONS

Only construction is checked: setting a required attribute to undef later,
through its accessor, is not refused.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
