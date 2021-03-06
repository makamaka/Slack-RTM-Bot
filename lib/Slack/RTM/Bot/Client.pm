package Slack::RTM::Bot::Client;

use strict;
use warnings;

use JSON;
use Encode;

use HTTP::Request::Common qw(POST);
use LWP::UserAgent;
use LWP::Protocol::https;

use Protocol::WebSocket::Client;
use IO::Socket::SSL qw/SSL_VERIFY_NONE/;

use Slack::RTM::Bot::Information;
use Slack::RTM::Bot::Response;

my $ua = LWP::UserAgent->new(
	ssl_opts => {
		verify_hostname => 0,
		SSL_verify_mode => SSL_VERIFY_NONE
	}
);
$ua->agent('Slack::RTM::Bot');

sub new {
	my $pkg = shift;
	my $self = {
		@_
	};
	die "token is required." unless $self->{token};
	return bless $self, $pkg;
}

sub connect {
	my $self = shift;
	my ($token) = @_;

	my $res = $ua->request(POST 'https://slack.com/api/rtm.start', [token => $token]);
	die 'response fail: ' . $res->content unless(JSON::from_json($res->content)->{ok});
	$self->{info} = Slack::RTM::Bot::Information->new(%{JSON::from_json($res->content)});

	$res = $ua->request(POST 'https://slack.com/api/im.list', [token => $token]);
	die 'response fail: ' . $res->content unless(JSON::from_json($res->content)->{ok});
	for my $im (@{JSON::from_json($res->content)->{ims}}) {
		my $name = $self->{info}->_find_user_name($im->{user});
		$self->{info}->{channels}->{$im->{id}} = {%$im, name => '@'.$name};
	}

	my ($host) = $self->{info}->{url} =~ m{wss://(.+)/websocket};
	my $socket = IO::Socket::SSL->new(
		SSL_verify_mode => SSL_VERIFY_NONE,
		PeerHost => $host,
		PeerPort => 443
	);
	$socket->blocking(0);
	$socket->connect;

	my $ws_client = Protocol::WebSocket::Client->new(url => $self->{info}->{url});
	$ws_client->on(read => sub {
			my ($cli, $buffer) = @_;
			$self->_listen($buffer);
		});
	$ws_client->on(write => sub {
			my ($cli, $buffer) = @_;
			syswrite $socket, $buffer;
		});
	$ws_client->on(connect => sub {
			print "RTM started.\n";
		});
	$ws_client->on(error => sub {
			my ($cli, $error) = @_;
			print STDERR 'error: '. JSON::to_json(JSON::from_json($error), {pretty => 1});
		});
	$ws_client->connect;

	$self->{ws_client} = $ws_client;
	$self->{socket} = $socket;
}

sub disconnect {
	my $self = shift;
	$self->{ws_client}->disconnect;
	undef $self;
}

sub read {
	my $self = shift;
	my $data = '';
	while (my $line = readline $self->{socket}) {
		$data .= $line;
	}
	$self->{ws_client}->read($data) if $data;
}

sub write {
	my $self = shift;
	$self->{ws_client}->write(JSON::to_json({@_}));
}

sub _listen {
	my $self = shift;
	my ($buffer) = @_;
	my $response = Slack::RTM::Bot::Response->new(
		buffer => JSON::from_json($buffer),
		info   => $self->{info}
	);
ACTION: for my $action(@{$self->{actions}}){
		for my $key(keys %{$action->{events}}){
			my $regex = $action->{events}->{$key};
			if(!defined $response->{$key} || $response->{$key} !~ $regex){
				next ACTION;
			}
		}
		$action->{routine}->($response);
	}
};

1;