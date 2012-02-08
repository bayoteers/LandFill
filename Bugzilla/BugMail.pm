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
# The Initial Developer of the Original Code is Netscape Communications
# Corporation. Portions created by Netscape are
# Copyright (C) 1998 Netscape Communications Corporation. All
# Rights Reserved.
#
# Contributor(s): Terry Weissman <terry@mozilla.org>,
#                 Bryce Nesbitt <bryce-mozilla@nextbus.com>
#                 Dan Mosedale <dmose@mozilla.org>
#                 Alan Raetz <al_raetz@yahoo.com>
#                 Jacob Steenhagen <jake@actex.net>
#                 Matthew Tuck <matty@chariot.net.au>
#                 Bradley Baetz <bbaetz@student.usyd.edu.au>
#                 J. Paul Reed <preed@sigkill.com>
#                 Gervase Markham <gerv@gerv.net>
#                 Byron Jones <bugzilla@glob.com.au>
#                 Reed Loden <reed@reedloden.com>

use strict;

package Bugzilla::BugMail;

use Bugzilla::Error;
use Bugzilla::User;
use Bugzilla::Constants;
use Bugzilla::Util;
use Bugzilla::Bug;
use Bugzilla::Classification;
use Bugzilla::Product;
use Bugzilla::Component;
use Bugzilla::Status;
use Bugzilla::Mailer;
use Bugzilla::Hook;

use Date::Parse;
use Date::Format;

use constant FORMAT_TRIPLE => "%19s|%-28s|%-28s";
use constant FORMAT_3_SIZE => [19,28,28];
use constant FORMAT_DOUBLE => "%19s %-55s";
use constant FORMAT_2_SIZE => [19,55];

use constant BIT_DIRECT    => 1;
use constant BIT_WATCHING  => 2;

# We use this instead of format because format doesn't deal well with
# multi-byte languages.
sub multiline_sprintf {
    my ($format, $args, $sizes) = @_;
    my @parts;
    my @my_sizes = @$sizes; # Copy this so we don't modify the input array.
    foreach my $string (@$args) {
        my $size = shift @my_sizes;
        my @pieces = split("\n", wrap_hard($string, $size));
        push(@parts, \@pieces);
    }

    my $formatted;
    while (1) {
        # Get the first item of each part.
        my @line = map { shift @$_ } @parts;
        # If they're all undef, we're done.
        last if !grep { defined $_ } @line;
        # Make any single undef item into ''
        @line = map { defined $_ ? $_ : '' } @line;
        # And append a formatted line
        $formatted .= sprintf($format, @line);
        # Remove trailing spaces, or they become lots of =20's in 
        # quoted-printable emails.
        $formatted =~ s/\s+$//;
        $formatted .= "\n";
    }
    return $formatted;
}

sub three_columns {
    return multiline_sprintf(FORMAT_TRIPLE, \@_, FORMAT_3_SIZE);
}

sub relationships {
    my $ref = RELATIONSHIPS;
    # Clone it so that we don't modify the constant;
    my %relationships = %$ref;
    Bugzilla::Hook::process('bugmail_relationships', 
                            { relationships => \%relationships });
    return %relationships;
}

# This is a bit of a hack, basically keeping the old system()
# cmd line interface. Should clean this up at some point.
#
# args: bug_id, and an optional hash ref which may have keys for:
# changer, owner, qa, reporter, cc
# Optional hash contains values of people which will be forced to those
# roles when the email is sent.
# All the names are email addresses, not userids
# values are scalars, except for cc, which is a list
sub Send {
    my ($id, $forced, $params) = (@_);
    $params ||= {};

    my $dbh = Bugzilla->dbh;
    my $bug = new Bugzilla::Bug($id);

    # Only used for headers in bugmail for new bugs
    my @fields = Bugzilla->get_fields({obsolete => 0, mailhead => 1});

    my $start = $bug->lastdiffed;
    my $end   = $dbh->selectrow_array('SELECT LOCALTIMESTAMP(0)');

    # Bugzilla::User objects of people in various roles. More than one person
    # can 'have' a role, if the person in that role has changed, or people are
    # watching.
    my @assignees = ($bug->assigned_to);
    my @qa_contacts = ($bug->qa_contact);

    my @ccs = @{ $bug->cc_users };

    # Include the people passed in as being in particular roles.
    # This can include people who used to hold those roles.
    # At this point, we don't care if there are duplicates in these arrays.
    my $changer = $forced->{'changer'};
    if ($forced->{'owner'}) {
        push (@assignees, Bugzilla::User->check($forced->{'owner'}));
    }
    
    if ($forced->{'qacontact'}) {
        push (@qa_contacts, Bugzilla::User->check($forced->{'qacontact'}));
    }
    
    if ($forced->{'cc'}) {
        foreach my $cc (@{$forced->{'cc'}}) {
            push(@ccs, Bugzilla::User->check($cc));
        }
    }
    
    my @args = ($bug->id);

    # If lastdiffed is NULL, then we don't limit the search on time.
    my $when_restriction = '';
    if ($start) {
        $when_restriction = ' AND bug_when > ? AND bug_when <= ?';
        push @args, ($start, $end);
    }
    
    my $diffs = $dbh->selectall_arrayref(
           "SELECT profiles.login_name, profiles.realname, fielddefs.description,
                   bugs_activity.bug_when, bugs_activity.removed, 
                   bugs_activity.added, bugs_activity.attach_id, fielddefs.name,
                   bugs_activity.comment_id
              FROM bugs_activity
        INNER JOIN fielddefs
                ON fielddefs.id = bugs_activity.fieldid
        INNER JOIN profiles
                ON profiles.userid = bugs_activity.who
             WHERE bugs_activity.bug_id = ?
                   $when_restriction
          ORDER BY bugs_activity.bug_when", undef, @args);

    my @new_depbugs;
    my $difftext = "";
    my $diffheader = "";
    my @diffparts;
    my $lastwho = "";
    my $fullwho;
    my @changedfields;
    foreach my $ref (@$diffs) {
        my ($who, $whoname, $what, $when, $old, $new, $attachid, $fieldname, $comment_id) = (@$ref);
        my $diffpart = {};
        if ($who ne $lastwho) {
            $lastwho = $who;
            $fullwho = $whoname ? "$whoname <$who>" : $who;
            $diffheader = "\n$fullwho changed:\n\n";
            $diffheader .= three_columns("What    ", "Removed", "Added");
            $diffheader .= ('-' x 76) . "\n";
        }
        $what =~ s/^(Attachment )?/Attachment #$attachid / if $attachid;
        if( $fieldname eq 'estimated_time' ||
            $fieldname eq 'remaining_time' ) {
            $old = format_time_decimal($old);
            $new = format_time_decimal($new);
        }
        if ($fieldname eq 'dependson') {
            push(@new_depbugs, grep {$_ =~ /^\d+$/} split(/[\s,]+/, $new));
        }
        if ($attachid) {
            ($diffpart->{'isprivate'}) = $dbh->selectrow_array(
                'SELECT isprivate FROM attachments WHERE attach_id = ?',
                undef, ($attachid));
        }
        if ($fieldname eq 'longdescs.isprivate') {
            my $comment = Bugzilla::Comment->new($comment_id);
            my $comment_num = $comment->count;
            $what =~ s/^(Comment )?/Comment #$comment_num /;
            $diffpart->{'isprivate'} = $new;
        }
        $difftext = three_columns($what, $old, $new);
        $diffpart->{'header'} = $diffheader;
        $diffpart->{'fieldname'} = $fieldname;
        $diffpart->{'text'} = $difftext;
        push(@diffparts, $diffpart);
        push(@changedfields, $what);
    }

    my @depbugs;
    my $deptext = "";
    # Do not include data about dependent bugs when they have just been added.
    # Completely skip checking for dependent bugs on bug creation as all
    # dependencies bugs will just have been added.
    if ($start) {
        my $dep_restriction = "";
        if (scalar @new_depbugs) {
            $dep_restriction = "AND bugs_activity.bug_id NOT IN (" .
                               join(", ", @new_depbugs) . ")";
        }

        my $dependency_diffs = $dbh->selectall_arrayref(
           "SELECT bugs_activity.bug_id, bugs.short_desc, fielddefs.name, 
                   fielddefs.description, bugs_activity.removed,
                   bugs_activity.added
              FROM bugs_activity
        INNER JOIN bugs
                ON bugs.bug_id = bugs_activity.bug_id
        INNER JOIN dependencies
                ON bugs_activity.bug_id = dependencies.dependson
        INNER JOIN fielddefs
                ON fielddefs.id = bugs_activity.fieldid
             WHERE dependencies.blocked = ?
               AND (fielddefs.name = 'bug_status'
                    OR fielddefs.name = 'resolution')
                   $when_restriction
                   $dep_restriction
          ORDER BY bugs_activity.bug_when, bugs.bug_id", undef, @args);

        my $thisdiff = "";
        my $lastbug = "";
        my $interestingchange = 0;
        foreach my $dependency_diff (@$dependency_diffs) {
            my ($depbug, $summary, $fieldname, $what, $old, $new) = @$dependency_diff;

            if ($depbug ne $lastbug) {
                if ($interestingchange) {
                    $deptext .= $thisdiff;
                }
                $lastbug = $depbug;
                $thisdiff =
                  "\nBug $id depends on bug $depbug, which changed state.\n\n" .
                  "Bug $depbug Summary: $summary\n" .
                  correct_urlbase() . "show_bug.cgi?id=$depbug\n\n";
                $thisdiff .= three_columns("What    ", "Old Value", "New Value");
                $thisdiff .= ('-' x 76) . "\n";
                $interestingchange = 0;
            }
            $thisdiff .= three_columns($what, $old, $new);
            if ($fieldname eq 'bug_status'
                && is_open_state($old) ne is_open_state($new))
            {
                $interestingchange = 1;
            }
            push(@depbugs, $depbug);
        }

        if ($interestingchange) {
            $deptext .= $thisdiff;
        }
        $deptext = trim($deptext);

        if ($deptext) {
            my $diffpart = {};
            $diffpart->{'text'} = "\n" . trim($deptext);
            push(@diffparts, $diffpart);
        }
    }

    my $comments = $bug->comments({ after => $start, to => $end });
    # Skip empty comments.
    @$comments = grep { $_->type || $_->body =~ /\S/ } @$comments;

    ###########################################################################
    # Start of email filtering code
    ###########################################################################
    
    # A user_id => roles hash to keep track of people.
    my %recipients;
    my %watching;
    
    # Now we work out all the people involved with this bug, and note all of
    # the relationships in a hash. The keys are userids, the values are an
    # array of role constants.
    
    # CCs
    $recipients{$_->id}->{+REL_CC} = BIT_DIRECT foreach (@ccs);
    
    # Reporter (there's only ever one)
    $recipients{$bug->reporter->id}->{+REL_REPORTER} = BIT_DIRECT;
    
    # QA Contact
    if (Bugzilla->params->{'useqacontact'}) {
        foreach (@qa_contacts) {
            # QA Contact can be blank; ignore it if so.
            $recipients{$_->id}->{+REL_QA} = BIT_DIRECT if $_;
        }
    }

    # Assignee
    $recipients{$_->id}->{+REL_ASSIGNEE} = BIT_DIRECT foreach (@assignees);

    # The last relevant set of people are those who are being removed from 
    # their roles in this change. We get their names out of the diffs.
    foreach my $ref (@$diffs) {
        my ($who, $whoname, $what, $when, $old, $new) = (@$ref);
        if ($old) {
            # You can't stop being the reporter, so we don't check that
            # relationship here.
            # Ignore people whose user account has been deleted or renamed.
            if ($what eq "CC") {
                foreach my $cc_user (split(/[\s,]+/, $old)) {
                    my $uid = login_to_id($cc_user);
                    $recipients{$uid}->{+REL_CC} = BIT_DIRECT if $uid;
                }
            }
            elsif ($what eq "QAContact") {
                my $uid = login_to_id($old);
                $recipients{$uid}->{+REL_QA} = BIT_DIRECT if $uid;
            }
            elsif ($what eq "AssignedTo") {
                my $uid = login_to_id($old);
                $recipients{$uid}->{+REL_ASSIGNEE} = BIT_DIRECT if $uid;
            }
        }
    }

    Bugzilla::Hook::process('bugmail_recipients',
                            { bug => $bug, recipients => \%recipients,
                              diffs => $diffs });

    # Find all those user-watching anyone on the current list, who is not
    # on it already themselves.
    my $involved = join(",", keys %recipients);

    my $userwatchers =
        $dbh->selectall_arrayref("SELECT watcher, watched FROM watch
                                  WHERE watched IN ($involved)");

    # Mark these people as having the role of the person they are watching
    foreach my $watch (@$userwatchers) {
        while (my ($role, $bits) = each %{$recipients{$watch->[1]}}) {
            $recipients{$watch->[0]}->{$role} |= BIT_WATCHING
                if $bits & BIT_DIRECT;
        }
        push(@{$watching{$watch->[0]}}, $watch->[1]);
    }

    # Global watcher
    my @watchers = split(/[,\s]+/, Bugzilla->params->{'globalwatchers'});
    foreach (@watchers) {
        my $watcher_id = login_to_id($_);
        next unless $watcher_id;
        $recipients{$watcher_id}->{+REL_GLOBAL_WATCHER} = BIT_DIRECT;
    }

    # We now have a complete set of all the users, and their relationships to
    # the bug in question. However, we are not necessarily going to mail them
    # all - there are preferences, permissions checks and all sorts to do yet.
    my @sent;
    my @excluded;

    # The email client will display the Date: header in the desired timezone,
    # so we can always use UTC here.
    my $date = $params->{dep_only} ? $end : $bug->delta_ts;
    $date = format_time($date, '%a, %d %b %Y %T %z', 'UTC');

    foreach my $user_id (keys %recipients) {
        my %rels_which_want;
        my $sent_mail = 0;
        my $user = new Bugzilla::User($user_id);
        # Deleted users must be excluded.
        next unless $user;

        if ($user->can_see_bug($id)) {
            # Go through each role the user has and see if they want mail in
            # that role.
            foreach my $relationship (keys %{$recipients{$user_id}}) {
                if ($user->wants_bug_mail($id,
                                          $relationship, 
                                          $diffs, 
                                          $comments,
                                          $deptext,
                                          $changer,
                                          !$start))
                {
                    $rels_which_want{$relationship} = 
                        $recipients{$user_id}->{$relationship};
                }
            }
        }
        
        if (scalar(%rels_which_want)) {
            # So the user exists, can see the bug, and wants mail in at least
            # one role. But do we want to send it to them?

            # We shouldn't send mail if this is a dependency mail (i.e. there 
            # is something in @depbugs), and any of the depending bugs are not 
            # visible to the user. This is to avoid leaking the summaries of 
            # confidential bugs.
            my $dep_ok = 1;
            foreach my $dep_id (@depbugs) {
                if (!$user->can_see_bug($dep_id)) {
                   $dep_ok = 0;
                   last;
                }
            }

            # Make sure the user isn't in the nomail list, and the insider and 
            # dep checks passed.
            if ($user->email_enabled && $dep_ok) {
                # OK, OK, if we must. Email the user.
                $sent_mail = sendMail(
                    { to       => $user, 
                      fields   => \@fields,
                      bug      => $bug,
                      comments => $comments,
                      is_new   => !$start,
                      date     => $date,
                      changer  => $changer,
                      watchers => exists $watching{$user_id} ?
                                  $watching{$user_id} : undef,
                      diff_parts      => \@diffparts,
                      rels_which_want => \%rels_which_want,
                      changed_fields  => \@changedfields,
                    });
            }
        }
       
        if ($sent_mail) {
            push(@sent, $user->login); 
        } 
        else {
            push(@excluded, $user->login); 
        } 
    }
    
    $dbh->do('UPDATE bugs SET lastdiffed = ? WHERE bug_id = ?',
             undef, ($end, $id));
    $bug->{lastdiffed} = $end;

    return {'sent' => \@sent, 'excluded' => \@excluded};
}

sub sendMail {
    my $params = shift;
    
    my $user   = $params->{to};
    my @fields = @{ $params->{fields} };
    my $bug    = $params->{bug};
    my @send_comments = @{ $params->{comments} };
    my $isnew   = $params->{is_new};
    my $date    = $params->{date};
    my $changer = $params->{changer};
    my $watchingRef = $params->{watchers};
    my @diffparts   = @{ $params->{diff_parts} };
    my $relRef      = $params->{rels_which_want};
    my @changed_fields = @{ $params->{changed_fields} };

    # Build difftext (the actions) by verifying the user should see them
    my $difftext = "";
    my $diffheader = "";
    my $add_diff;

    foreach my $diff (@diffparts) {
        $add_diff = 0;
        
        if (exists($diff->{'fieldname'}) && 
            ($diff->{'fieldname'} eq 'estimated_time' ||
             $diff->{'fieldname'} eq 'remaining_time' ||
             $diff->{'fieldname'} eq 'work_time' ||
             $diff->{'fieldname'} eq 'deadline'))
        {
            $add_diff = 1 if $user->is_timetracker;
        } elsif ($diff->{'isprivate'} 
                 && !$user->is_insider)
        {
            $add_diff = 0;
        } else {
            $add_diff = 1;
        }

        if ($add_diff) {
            if (exists($diff->{'header'}) && 
             ($diffheader ne $diff->{'header'})) {
                $diffheader = $diff->{'header'};
                $difftext .= $diffheader;
            }
            $difftext .= $diff->{'text'};
        }
    }

    if (!$user->is_insider) {
        @send_comments = grep { !$_->is_private } @send_comments;
    }

    if ($difftext eq "" && !scalar(@send_comments) && !$isnew) {
      # Whoops, no differences!
      return 0;
    }

    my $diffs = $difftext;
    # Remove extra newlines.
    $diffs =~ s/^\n+//s; $diffs =~ s/\n+$//s;
    if ($isnew) {
        my $head = "";
        foreach my $field (@fields) {
            my $name = $field->name;
            my $value = $bug->$name;

            if (ref $value eq 'ARRAY') {
                $value = join(', ', @$value);
            }
            elsif (ref $value && $value->isa('Bugzilla::User')) {
                $value = $value->login;
            }
            elsif (ref $value && $value->isa('Bugzilla::Object')) {
                $value = $value->name;
            }
            elsif ($name eq 'estimated_time') {
                $value = ($value == 0) ? 0 : format_time_decimal($value);
            }
            elsif ($name eq 'deadline') {
                $value = time2str("%Y-%m-%d", str2time($value)) if $value;
            }

            # If there isn't anything to show, don't include this header.
            next unless $value;
            # Only send estimated_time if it is enabled and the user is in the group.
            if (($name ne 'estimated_time' && $name ne 'deadline') || $user->is_timetracker) {
                my $desc = $field->description;
                $head .= multiline_sprintf(FORMAT_DOUBLE, ["$desc:", $value],
                                           FORMAT_2_SIZE);
            }
        }
        $diffs = $head . ($difftext ? "\n\n" : "") . $diffs;
    }

    my (@reasons, @reasons_watch);
    while (my ($relationship, $bits) = each %{$relRef}) {
        push(@reasons, $relationship) if ($bits & BIT_DIRECT);
        push(@reasons_watch, $relationship) if ($bits & BIT_WATCHING);
    }

    my %relationships = relationships();
    my @headerrel   = map { $relationships{$_} } @reasons;
    my @watchingrel = map { $relationships{$_} } @reasons_watch;
    push(@headerrel,   'None') unless @headerrel;
    push(@watchingrel, 'None') unless @watchingrel;
    push @watchingrel, map { user_id_to_login($_) } @$watchingRef;

    my $vars = {
        isnew => $isnew,
        date => $date,
        to_user => $user,
        bug => $bug,
        changedfields => \@changed_fields,
        reasons => \@reasons,
        reasons_watch => \@reasons_watch,
        reasonsheader => join(" ", @headerrel),
        reasonswatchheader => join(" ", @watchingrel),
        changer => $changer,
        diffs => $diffs,
        new_comments => \@send_comments,
        threadingmarker => build_thread_marker($bug->id, $user->id, $isnew),
    };

    my $msg;
    my $template = Bugzilla->template_inner($user->settings->{'lang'}->{'value'});
    $template->process("email/newchangedmail.txt.tmpl", $vars, \$msg)
      || ThrowTemplateError($template->error());

    MessageToMTA($msg);

    return 1;
}

1;
