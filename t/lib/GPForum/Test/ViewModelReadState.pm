# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ViewModelReadState;

use v5.40;

our $VERSION = '0.001';

# A read state for a signed-in member whose first unread post is post-1.

sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub summary_for_page {
    return {
        authenticated         => 1,
        first_unread_anchor   => 'post-post-1',
        last_visible_position => 2,
    };
}

1;
