# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::OfflineStore;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A store whose database is gone: each call a test sends dies, as a store's
# does when its connection drops -- a notification preference store's, a role
# catalog's, a moderation action store's, a deletion workflow's, the identity
# store's, a bookmark store's.
sub channel_enabled ( $, $, $ ) {
    die "store offline\n";
}

sub create_role ( $, $ ) {
    die "store offline\n";
}

sub hide_post ( $, $ ) {
    die "store offline\n";
}

sub request_deletion ( $, $ ) {
    die "store offline\n";
}

sub request_password_reset ( $, $ ) {
    die "store offline\n";
}

sub save_bookmark ( $, $ ) {
    die "store offline\n";
}

sub set_preferences ( $, $ ) {
    die "store offline\n";
}

1;
