package modules::local::githubparser;
use strict;
use warnings;

use XML::Atom::Client;
use HTML::Entities;

use base 'modules::local::karmalog';

=head1 NAME

    modules::local::githubparser

=head1 DESCRIPTION

This module is responsible for parsing ATOM feeds generated by github.com.  It
is also knowledgeable enough about github's URL schemes to be able to recognise
repository URLs, extract the project name/owner/path and generate ATOM feed
URLs.

=cut


# When new feeds are configured, this number  is incremented and added to the
# base timer interval in an attempt to stagger their occurance in time.
our $feed_number = 1;

# This is a map of $self objects.  Because botnix does not use full class
# instances and instead calls package::name->function() to call methods, the
# actual OO storage for those modules ends up in here.
our %objects_by_package;


=head1 METHODS

=head2 fetch_feed

This is a pseudomethod called as a timer callback.  It fetches the feed, parses
it into an XML::Atom::Feed object and passes that to process_feed().

This is the main entry point to this module.  Botnix does not use full class
instances, instead it just calls by package name.  This function maps from the
function name to a real $self object (stored in %objects_by_package).

=cut

sub fetch_feed {
    my $pkg  = shift;
    my $self = $objects_by_package{$pkg};
    my $atom = XML::Atom::Client->new();
    my $feed = $atom->getFeed($$self{url});
    $pkg->process_feed($feed);
}


=head2 process_feed

    $self->process_feed($feed);

Enumerates the commits in the feed, emitting any events it hasn't seen before.
This subroutine manages a "seen" cache in $self, and will take care not to
announce any commit more than once.

The first time through, nothing is emitted.  This is because we assume the bot
was just restarted ungracefully and the users have already seen all the old
events.  So it just populates the seen-cache silently.

=cut

sub process_feed {
    my ($pkg, $feed) = @_;
    my $self = $objects_by_package{$pkg};
    my @items = $feed->entries;
    @items = sort { $a->updated cmp $b->updated } @items; # ascending order
    my $newest = $items[-1];
    my $latest = $newest->updated;

    # skip the first run, to prevent new installs from flooding the channel
    foreach my $item (@items) {
        my $link    = $item->link->href;
        my ($rev)   = $link =~ m|/commit/([a-z0-9]{40})|;
        if(exists($$self{not_first_time})) {
            # output new entries to channel
            next if exists($$self{seen}{$rev});
            $$self{seen}{$rev} = 1;
            $self->output_item($item, $link, $rev);
        } else {
            $$self{seen}{$rev} = 1;
        }
    }
    $$self{not_first_time} = 1;
}


=head2 longest_common_prefix

    my $prefix = longest_common_prefix(@files);

Given a list of filenames, like ("src/ops/perl6.ops", "src/classes/IO.pir"),
returns the common prefix portion.  For the example I just gave, the common
prefix would be "src/".
=cut

sub longest_common_prefix {
    my $prefix = shift;
    for (@_) {
        chop $prefix while (! /^\Q$prefix\E/);
    }
    return $prefix;
}


=head2 try_link

    modules::local::githubparser->try_link($url, ['network', '#channel']);

This is called by autofeed.pm.  Given a github.com URL, try to determine the
project name and canonical path.  Then configure a feed reader for it if one
doesn't already exist.

The array reference containing network and channel are optional.  If not
specified, magnet/#parrot is assumed.  If the feed already exists but didn't
have the specified target, the existing feed is extended.

Currently supports 3 URL formats:

    http://github.com/tene/gil/
    http://wiki.github.com/TiMBuS/fun
    http://bschmalhofer.github.com/hq9plus/

...with or without a suffix of "/" or "/tree/master".  This covers all of the
links on the Languages page at time of writing.

=cut

sub try_link {
    my ($pkg, $url, $target) = @_;
    $target = ['magnet', '#parrot'] unless defined $target;
    my($author, $project);
    if($url =~ m|http://(?:wiki.)?github.com/([^/]+)/([^/]+)/?|) {
        $author  = $1;
        $project = $2;
    } elsif($url =~ m|http://([^.]+).github.com/([^/]+)/?|) {
        $author  = $1;
        $project = $2;
    } else {
        # whatever it is, we can't handle it.  Log and return.
        main::lprint("github try_link(): I can't handle $url");
        return;
    }

    my $parsername = $project . "log";
    my $modulename = "modules::local::" . $parsername;
    $modulename =~ s/-/_/g;
    if(exists($objects_by_package{$modulename})) {
        # extend existing feed if necessary
        my $self = $objects_by_package{$modulename};
        my $already_have_target = 0;
        foreach my $this (@{$$self{targets}}) {
            $already_have_target++
                if($$target[0] eq $$this[0] && $$target[1] eq $$this[1]);
        }
        push(@{$$self{targets}}, $target) unless $already_have_target;
        return;
    }

    # create new feed
    # url, feed_name, targets, objects_by_package
    my $rss_link = "http://github.com/feeds/$author/commits/$project/master";
    my $self = {
        url        => $rss_link,
        feed_name  => $project,
        modulename => $modulename,
        targets    => [ $target ],
    };
    # create a dynamic subclass to get the timer callback back to us
    eval "package $modulename; use base 'modules::local::githubparser';";
    $objects_by_package{$modulename} = bless($self, $modulename);
    main::lprint("$parsername github ATOM parser autoloaded.");
    main::create_timer($parsername."_fetch_feed_timer", $modulename,
        "fetch_feed", 300 + $feed_number++);
}


=head2 output_item

    $self->output_item($item, $link, $revision);

Takes an XML::Atom::Entry object, extracts the useful bits from it and calls
put() to emit the karma message.

The karma message is typically as follows:

feedname: $revision | username++ | $commonprefix:
feedname: One or more lines of commit log message
feedname: review: http://link/to/github/diff/page

=cut

sub output_item {
    my ($self, $item, $link, $rev) = @_;
    my $prefix  = 'unknown';
    my $creator = $item->author;
    if(defined($creator)) {
        $creator = $creator->name;
    } else {
        $creator = 'unknown';
    }
    my $desc    = $item->content;
    if(defined($desc)) {
        $desc = $desc->body;
    } else {
        $desc = '(no commit message)';
    }

    my ($log, $files);
    $desc =~ s/^.*<pre>//;
    $desc =~ s/<\/pre>.*$//;
    my @lines = split("\n", $desc);
    my @files;
    while($lines[0] =~ /^[+m-] (.+)/) {
        push(@files, $1);
        shift(@lines);
    }
    return main::lprint($$self{feed_name}.": error parsing filenames from description")
        unless $lines[0] eq '';
    shift(@lines);
    pop(@lines) if $lines[-1] =~ /^git-svn-id: http:/;
    pop(@lines) while scalar(@lines) && $lines[-1] eq '';
    $log = join("\n", @lines);

    $prefix =  longest_common_prefix(@files);
    $prefix //= '/';
    $prefix =~ s|^/||;      # cut off the leading slash
    if(scalar @files > 1) {
        $prefix .= " (" . scalar(@files) . " files)";
    }

    $log =~ s|<br */>||g;
    decode_entities($log);
    my @log_lines = split(/[\r\n]+/, $log);
    $rev = substr($rev, 0, 7);

    $self->emit_karma_message(
        feed    => $$self{feed_name},
        rev     => $rev,
        user    => $creator,
        log     => \@log_lines,
        link    => $link,
        prefix  => $prefix,
        targets => $$self{targets},
    );

    main::lprint($$self{feed_name}.": output_item: output rev $rev");
}


=head2 implements

This is a pseudo-method called by botnix to determine which event callbacks
this module supports.  It is only called when explicitly subclassed (rakudo
does this).  Returns an empty array.

=cut

sub implements {
    return qw();
}


=head2 get_self

This is a helper method used by the test suite to fetch a feed's local state.
It isn't used in production.

=cut

sub get_self {
    my $pkg = shift;
    return $objects_by_package{$pkg};
}

1;
