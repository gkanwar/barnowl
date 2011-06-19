use warnings;
use strict;

=head1 NAME

BarnOwl::Module::Facebook::Handle

=head1 DESCRIPTION

Contains everything needed to send and receive messages from Facebook

=cut

package BarnOwl::Module::Facebook::Handle;

use Facebook::Graph;
use Data::Dumper;
use JSON;

use Scalar::Util qw(weaken);

use BarnOwl;
use BarnOwl::Message::Facebook;

our $app_id = 235537266461636; # for application 'barnowl'

sub fail {
    my $self = shift;
    my $msg  = shift;
    undef $self->{facebook};
    die("[Facebook] Error: $msg\n");
}

sub new {
    my $class = shift;
    my $cfg = shift;

    my $self = {
        'cfg'  => $cfg,
        'facebook' => undef,
        'last_poll' => time - 60 * 60 * 24,
        'last_message_poll' => time,
        'timer' => undef,
        'message_timer' => undef,
        # yeah yeah, inelegant, I know.  You can try using
        # $fb->authorize, but at time of writing (1.0300) they didn't support
        # the response_type parameter.
        # 'login_url' => 'https://www.facebook.com/dialog/oauth?client_id=235537266461636&scope=read_stream,read_mailbox,publish_stream,offline_access&redirect_uri=http://www.facebook.com/connect/login_success.html&response_type=token',
        # minified to fit in most terminal windows.
        'login_url' => 'http://goo.gl/yA42G',
        'logged_in' => 0
    };

    bless($self, $class);

    $self->{facebook} = Facebook::Graph->new( app_id => $app_id );
    $self->facebook_do_auth;

    return $self;
}

=head2 sleep N

Stop polling Facebook for N seconds.

=cut

sub sleep {
    my $self  = shift;
    my $delay = shift;

    # prevent reference cycles
    my $weak = $self;
    weaken($weak);

    # Stop any existing timers.
    if (defined $self->{timer}) {
        $self->{timer}->stop;
        $self->{timer} = undef;
    }
    if (defined $self->{message_timer}) {
        # XXX doesn't do anything right now
        $self->{message_timer}->stop;
        $self->{message_timer} = undef;
    }

    $self->{timer} = BarnOwl::Timer->new({
        name     => "Facebook poll",
        after    => $delay,
        interval => 90,
        cb       => sub { $weak->poll_facebook if $weak }
       });
    # XXX implement message polling
}

sub die_on_error {
    my $self = shift;
    my $error = shift;

    die "$error" if $error;
}

sub poll_facebook {
    my $self = shift;

    #return unless ( time - $self->{last_poll} ) >= 60;
    return unless BarnOwl::getvar('facebook:poll') eq 'on';
    return unless $self->{logged_in};

    #BarnOwl::message("Polling Facebook...");

    # blah blah blah

    my $updates = eval {
        $self->{facebook}
             ->query
             ->from("my_news")
             # ->include_metadata()
             # ->select_fields( ??? )
             ->where_since( "@" . $self->{last_poll} )
             ->request()
             ->as_hashref()
    };

    $self->{last_poll} = time;
    $self->die_on_error($@);

    #warn Dumper($updates);

    for my $post ( reverse @{$updates->{data}} ) {
        # no app invites, thanks! (XXX make configurable)
        if ($post->{type} eq 'link' && $post->{application}) {
            next;
        }
        # XXX need to somehow access Facebook's user hiding mechanism...
        # indexing is fragile
        my $msg = BarnOwl::Message->new(
            type      => 'Facebook',
            sender    => $post->{from}{name},
            sender_id => $post->{from}{id},
            name      => $post->{to}{data}[0]{name} || $post->{from}{name},
            name_id   => $post->{to}{data}[0]{id} || $post->{from}{id},
            direction => 'in',
            body      => $self->format_body($post),
            postid    => $post->{id},
            zsig      => $post->{actions}[0]{link},
           );
        BarnOwl::queue_message($msg);
    }
}

sub format_body {
    my $self = shift;

    my $post = shift;

    # XXX implement optional URL minification
    if ($post->{type} eq 'status') {
        return $post->{message};
    } elsif ($post->{type} eq 'link' || $post->{type} eq 'video' || $post->{type} eq 'photo') {
        return $post->{name}
          . ($post->{caption} ? " (" . $post->{caption} . ")\n" : "\n")
          . $post->{link}
          . ($post->{description} ? "\n\n" . $post->{description} : "")
          . ($post->{message} ? "\n\n" . $post->{message} : "");
    } else {
        return "(unknown post type " . $post->{type} . ")";
    }
}

sub facebook {
    my $self = shift;

    my $msg = shift;
    my $reply_to = shift;

    if (!defined $self->{facebook} || !$self->{logged_in}) {
        BarnOwl::admin_message('Facebook', 'You are not currently logged into Facebook.');
        return;
    }
    $self->{facebook}->add_post->set_message( $msg )->publish;
    $self->poll_facebook;
}

sub facebook_comment {
    my $self = shift;

    my $postid = shift;
    my $msg = shift;

    $self->{facebook}->add_comment( $postid )->set_message( $msg )->publish;
}

sub facebook_auth {
    my $self = shift;

    my $url = shift;
    # http://www.facebook.com/connect/login_success.html#access_token=TOKEN&expires_in=0
    $url =~ /access_token=([^&]+)/; # XXX Ew regex

    $self->{cfg}->{token} = $1;
    if ($self->facebook_do_auth) {
        my $raw_cfg = to_json($self->{cfg});
        BarnOwl::admin_message('Facebook', "Add this as the contents of your ~/.owl/facebook file:\n$raw_cfg");
    }
}

sub facebook_do_auth {
    my $self = shift;
    if ( ! defined $self->{cfg}->{token} ) {
        BarnOwl::admin_message('Facebook', "Login to Facebook at ".$self->{login_url}
            . "\nand run command ':facebook-auth URL' with the URL you are redirected to.");
        return 0;
    }
    $self->{facebook}->access_token($self->{cfg}->{token});
    # Do a quick check to see if things are working
    my $result = eval { $self->{facebook}->fetch('me'); };
    if ($@) {
        BarnOwl::admin_message('Facebook', "Failed to authenticate! Login to Facebook at ".$self->{login_url}
            . "\nand run command ':facebook-auth URL' with the URL you are redirected to.");
        return 0;
    } else {
        my $name = $result->{'name'};
        BarnOwl::admin_message('Facebook', "Successfully logged in to Facebook as $name!");
        $self->{logged_in} = 1;
        $self->sleep(0); # start polling
        return 1;
    }
}

1;