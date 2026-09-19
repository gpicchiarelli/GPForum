package GPForum::ViewModel::Forum::Presenter;

use strict;
use warnings;

use GPForum::ViewModel::Forum::Form;
use Mojo::Base 'GPForum::ViewModel::Forum::Page';

our $VERSION = '0.001';

has form => sub { return GPForum::ViewModel::Forum::Form->new; };

sub new_thread_form {
    my ( $self, %input ) = @_;

    return $self->form->new_thread_form(%input);
}

1;
