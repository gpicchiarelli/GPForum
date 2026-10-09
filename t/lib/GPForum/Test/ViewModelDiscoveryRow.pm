# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ViewModelDiscoveryRow;

use v5.40;

our $VERSION = '0.001';

# One public thread as the sitemap and feed read it.

sub new {
    my ($class) = @_;

    return bless {
        category_id => 'category-1',
        slug        => 'welcome',
        thread_id   => 'thread-1',
        title       => 'Welcome',
    }, $class;
}

sub columns {
    return qw(category_id slug thread_id title);
}

sub get_column {
    my ( $self, $name ) = @_;

    return $self->{$name};
}

1;
