#!/usr/bin/perl -wT
# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Bugzilla Bug Tracking System.
#
# Contributor(s): Max Kanat-Alexander <mkanat@bugzilla.org>

package Bugzilla::ModPerl;

use strict;
use warnings;

# This sets up our libpath without having to specify it in the mod_perl
# configuration.
use File::Basename;
use lib dirname(__FILE__);
use Bugzilla::Constants ();
use lib Bugzilla::Constants::bz_locations()->{'ext_libpath'};

# If you have an Apache2::Status handler in your Apache configuration,
# you need to load Apache2::Status *here*, so that any later-loaded modules
# can report information to Apache2::Status.
#use Apache2::Status ();

# We don't want to import anything into the global scope during
# startup, so we always specify () after using any module in this
# file.

use Apache2::ServerUtil;
use ModPerl::RegistryLoader ();
use CGI ();
CGI->compile(qw(:cgi -no_xhtml -oldstyle_urls :private_tempfiles
                :unique_headers SERVER_PUSH :push));
use File::Basename ();
use Template::Config ();
Template::Config->preload();

# For PerlChildInitHandler
eval { require Math::Random::Secure };

use Bugzilla ();
use Bugzilla::CGI ();
use Bugzilla::Extension ();
use Bugzilla::Install::Requirements ();
use Bugzilla::Mailer ();
use Bugzilla::Template ();
use Bugzilla::Util ();

use Apache2::SizeLimit;
# This means that every httpd child will die after processing
# a CGI if it is taking up more than 70MB of RAM all by itself.
Apache2::SizeLimit->set_max_unshared_size(70_000);

my $cgi_path = Bugzilla::Constants::bz_locations()->{'cgi_path'};

# Set up the configuration for the web server
my $server = Apache2::ServerUtil->server;
my $conf = <<EOT;
# Make sure each httpd child receives a different random seed (bug 476622).
# Math::Random::Secure has one srand that needs to be called for
# every process, and Perl has another. (Various Perl modules still use
# the built-in rand(), even though we only use Math::Random::Secure in
# Bugzilla itself, so we need to srand() both of them.) However, 
# Math::Random::Secure may not be installed, so we call its srand in an
# eval.
PerlChildInitHandler "sub { eval { Math::Random::Secure::srand() }; srand(); }"
<Directory "$cgi_path">
    AddHandler perl-script .cgi
    # No need to PerlModule these because they're already defined in mod_perl.pl
    PerlResponseHandler Bugzilla::ModPerl::ResponseHandler
    PerlCleanupHandler  Apache2::SizeLimit Bugzilla::ModPerl::CleanupHandler
    PerlOptions +ParseHeaders
    Options +ExecCGI
    AllowOverride Limit FileInfo Indexes
    DirectoryIndex index.cgi index.html
</Directory>
EOT

$server->add_config([split("\n", $conf)]);

# Pre-load all extensions
$Bugzilla::extension_packages = Bugzilla::Extension->load_all();

# Have ModPerl::RegistryLoader pre-compile all CGI scripts.
my $rl = new ModPerl::RegistryLoader();
# If we try to do this in "new" it fails because it looks for a 
# Bugzilla/ModPerl/ResponseHandler.pm
$rl->{package} = 'Bugzilla::ModPerl::ResponseHandler';
my $feature_files = Bugzilla::Install::Requirements::map_files_to_features();

# Prevent "use lib" from doing anything when the .cgi files are compiled.
# This is important to prevent the current directory from getting into
# @INC and messing things up. (See bug 630750.)
no warnings 'redefine';
local *lib::import = sub {};
use warnings;

foreach my $file (glob "$cgi_path/*.cgi") {
    my $base_filename = File::Basename::basename($file);
    if (my $feature = $feature_files->{$base_filename}) {
        next if !Bugzilla->feature($feature);
    }
    Bugzilla::Util::trick_taint($file);
    $rl->handler($file, $file);
}

package Bugzilla::ModPerl::ResponseHandler;
use strict;
use base qw(ModPerl::Registry);
use Bugzilla;

sub handler : method {
    my $class = shift;

    # $0 is broken under mod_perl before 2.0.2, so we have to set it
    # here explicitly or init_page's shutdownhtml code won't work right.
    $0 = $ENV{'SCRIPT_FILENAME'};

    # Prevent "use lib" from modifying @INC in the case where a .cgi file
    # is being automatically recompiled by mod_perl when Apache is
    # running. (This happens if a file changes while Apache is already
    # running.)
    no warnings 'redefine';
    local *lib::import = sub {};
    use warnings;

    Bugzilla::init_page();
    return $class->SUPER::handler(@_);
}


package Bugzilla::ModPerl::CleanupHandler;
use strict;
use Apache2::Const -compile => qw(OK);

sub handler {
    my $r = shift;

    Bugzilla::_cleanup();
    # Sometimes mod_perl doesn't properly call DESTROY on all
    # the objects in pnotes()
    foreach my $key (keys %{$r->pnotes}) {
        delete $r->pnotes->{$key};
    }

    return Apache2::Const::OK;
}

1;
