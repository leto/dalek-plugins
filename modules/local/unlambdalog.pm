package modules::local::unlambdalog;
use strict;
use warnings;
use SUPER;
use base qw(modules::local::githubparser);

my $url = 'http://github.com/feeds/bschmalhofer/commits/unlambda/master';

sub init {
    my $self = shift;
    $self = bless({modulename => $self}, $self) unless ref($self);
    $$self{url}       = $url;
    $$self{feed_name} = 'unlambda';
    $$self{targets}   = [
        [ "magnet",   "#parrot" ],
    ];
    my $initfunc = $self->super('init');
    $initfunc->($self);
}

1;