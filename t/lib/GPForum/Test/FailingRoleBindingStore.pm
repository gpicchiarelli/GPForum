# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::FailingRoleBindingStore;

use Carp qw(croak);
use Mojo::Base 'GPForum::Service::Admin::RoleBindingStore';
use v5.40;

our $VERSION = '0.001';

# Every insert throws, as a store whose database went away would.
sub _create_binding {    ## no critic (Subroutines::ProhibitUnusedPrivateSubroutines) -- overrides the store's insert step
    croak 'role binding store offline';
}

1;
