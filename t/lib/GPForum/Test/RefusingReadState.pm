# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RefusingReadState;

use v5.40;

our $VERSION = '0.001';

# A read state whose every mark is refused with the answer it was built
# with, as ReadState refuses an invalid mark.
sub new ( $class, $refusal ) {
    return bless { refusal => $refusal }, $class;
}

sub mark_thread_read ( $self, $input ) {
    return { %{ $self->{refusal} } };
}

1;
