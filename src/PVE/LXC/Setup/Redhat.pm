package PVE::LXC::Setup::Redhat;

use strict;
use warnings;
use Data::Dumper;
use PVE::Tools;
use PVE::Network;
use PVE::LXC;

use PVE::LXC::Setup::Base;

use base qw(PVE::LXC::Setup::Base);

sub new {
    my ($class, $conf, $rootdir) = @_;

    my $release = PVE::Tools::file_read_firstline("$rootdir/etc/redhat-release");
    die "unable to read version info\n" if !defined($release);

    my $version;

    if ($release =~ m/release\s+(\d+\.\d+)(\.\d+)?/) {
	if ($1 >= 6 && $1 < 8) {
	    $version = $1;
	}
    }

    die "unsupported redhat release '$release'\n" if !$version;

    my $self = { conf => $conf, rootdir => $rootdir, version => $version };

    $conf->{ostype} = "centos";

    return bless $self, $class;
}

my $tty_conf = <<__EOD__;
# tty - getty
#
# This service maintains a getty on the specified device.
#
# Do not edit this file directly. If you want to change the behaviour,
# please create a file tty.override and put your changes there.

stop on runlevel [S016]

respawn
instance \$TTY
exec /sbin/mingetty \$TTY
usage 'tty TTY=/dev/ttyX  - where X is console id'
__EOD__
    
my $start_ttys_conf = <<__EOD__;
#
# This service starts the configured number of gettys.
#
# Do not edit this file directly. If you want to change the behaviour,
# please create a file start-ttys.override and put your changes there.

start on stopped rc RUNLEVEL=[2345]

env ACTIVE_CONSOLES=/dev/tty[1-6]
env X_TTY=/dev/tty1
task
script
        . /etc/sysconfig/init
        for tty in \$(echo \$ACTIVE_CONSOLES) ; do
                [ "\$RUNLEVEL" = "5" -a "\$tty" = "\$X_TTY" ] && continue
                initctl start tty TTY=\$tty
        done
end script
__EOD__

my $power_status_changed_conf = <<__EOD__;
#  power-status-changed - shutdown on SIGPWR
#
start on power-status-changed
    
exec /sbin/shutdown -h now "SIGPWR received"
__EOD__

sub template_fixup {
    my ($self, $conf) = @_;

    if ($self->{version} < 7) {
	# re-create emissing files for tty

	$self->ct_mkpath('/etc/init');

	my $filename = "/etc/init/tty.conf";
	$self->ct_file_set_contents($filename, $tty_conf)
	    if ! $self->ct_file_exists($filename);

	$filename = "/etc/init/start-ttys.conf";
	$self->ct_file_set_contents($filename, $start_ttys_conf)
	    if ! $self->ct_file_exists($filename);

	$filename = "/etc/init/power-status-changed.conf";
	$self->ct_file_set_contents($filename, $power_status_changed_conf)
	    if ! $self->ct_file_exists($filename);

	# do not start udevd
	$filename = "/etc/rc.d/rc.sysinit";
	my $data = $self->ct_file_get_contents($filename);
	$data =~ s!^(/sbin/start_udev.*)$!#$1!gm;
	$self->ct_file_set_contents($filename, $data);
	
	# edit /etc/securetty (enable login on console)
	$self->setup_securetty($conf, qw(lxc/console lxc/tty1 lxc/tty2 lxc/tty3 lxc/tty4));
    }
}

sub setup_init {
    my ($self, $conf) = @_;

     # edit/etc/securetty

    $self->setup_systemd_console($conf);
}

sub set_hostname {
    my ($self, $conf) = @_;

    # Redhat wants the fqdn in /etc/sysconfig/network's HOSTNAME
    my $hostname = $conf->{hostname} || 'localhost';

    my $hostname_fn = "/etc/hostname";
    my $sysconfig_network = "/etc/sysconfig/network";

    my $oldname;
    if ($self->ct_file_exists($hostname_fn)) {
	$oldname = $self->ct_file_read_firstline($hostname_fn) || 'localhost';
    } else {
	my $data = $self->ct_file_get_contents($sysconfig_network);
	if ($data =~ m/^HOSTNAME=\s*(\S+)\s*$/m) {
	    $oldname = $1;
	}
    }

    my $hosts_fn = "/etc/hosts";
    my $etc_hosts_data = '';
    if ($self->ct_file_exists($hosts_fn)) {
	$etc_hosts_data =  $self->ct_file_get_contents($hosts_fn);
    }

    my ($ipv4, $ipv6) = PVE::LXC::get_primary_ips($conf);
    my $hostip = $ipv4 || $ipv6;

    my ($searchdomains) = PVE::LXC::Setup::Base::lookup_dns_conf($conf);

    $etc_hosts_data = PVE::LXC::Setup::Base::update_etc_hosts($etc_hosts_data, $hostip, $oldname,
							    $hostname, $searchdomains);

    if ($self->ct_file_exists($hostname_fn)) {
	$self->ct_file_set_contents($hostname_fn, "$hostname\n");
    } else {
	my $data = $self->ct_file_get_contents($sysconfig_network);
	if ($data !~ s/^HOSTNAME=\s*(\S+)\s*$/HOSTNAME=$hostname/m) {
	    $data .= "HOSTNAME=$hostname\n";
	}
	my ($has_ipv4, $has_ipv6);
	foreach my $k (keys %$conf) {
	    next if $k !~ m/^net(\d+)$/;
	    my $d = PVE::LXC::parse_lxc_network($conf->{$k});
	    next if !$d->{name};
	    $has_ipv4 = 1 if defined($d->{ip});
	    $has_ipv6 = 1 if defined($d->{ip6});
	}
	if ($has_ipv4) {
	    if ($data !~ s/(NETWORKING)=\S+/$1=yes/) {
		$data .= "NETWORKING=yes\n";
	    }
	}
	if ($has_ipv6) {
	    if ($data !~ s/(NETWORKING_IPV6)=\S+/$1=yes/) {
		$data .= "NETWORKING_IPV6=yes\n";
	    }
	}
	$self->ct_file_set_contents($sysconfig_network, $data);
    }

    $self->ct_file_set_contents($hosts_fn, $etc_hosts_data);
}

sub setup_network {
    my ($self, $conf) = @_;

    my ($gw, $gw6);

    $self->ct_mkpath('/etc/sysconfig/network-scripts');

    foreach my $k (keys %$conf) {
	next if $k !~ m/^net(\d+)$/;
	my $d = PVE::LXC::parse_lxc_network($conf->{$k});
	next if !$d->{name};

	my $filename = "/etc/sysconfig/network-scripts/ifcfg-$d->{name}";
	my $routefile = "/etc/sysconfig/network-scripts/route-$d->{name}";
	my $routes = '';
	my $had_v4 = 0;

	if ($d->{ip} && $d->{ip} ne 'manual') {
	    my $data = "DEVICE=$d->{name}\n";
	    $data .= "ONBOOT=yes\n";
	    if ($d->{ip} eq 'dhcp') {
		$data .= "BOOTPROTO=dhcp\n";
	    } else {
		$data .= "BOOTPROTO=none\n";
		my $ipinfo = PVE::LXC::parse_ipv4_cidr($d->{ip});
		$data .= "IPADDR=$ipinfo->{address}\n";
		$data .= "NETMASK=$ipinfo->{netmask}\n";
		if (defined($d->{gw})) {
		    $data .= "GATEWAY=$d->{gw}\n";
		}
	    }
	    $self->ct_file_set_contents($filename, $data);
	    if (!PVE::Network::is_ip_in_cidr($d->{gw}, $d->{ip}, 4)) {
		$routes .= "$d->{gw} dev $d->{name}\n";
		$routes .= "default via $d->{gw}\n";
	    }
	    # If we also have an IPv6 configuration it'll end up in an alias
	    # interface becuase otherwise RH doesn't support mixing dhcpv4 with
	    # a static ipv6 address.
	    $filename .= ':0';
	    $had_v4 = 1;
	}

	if ($d->{ip6} && $d->{ip6} ne 'manual') {
	    # If we're only on ipv6 delete the :0 alias
	    $self->ct_unlink("$filename:0") if !$had_v4;

	    my $data = "DEVICE=$d->{name}\n";
	    $data .= "ONBOOT=yes\n";
	    $data .= "BOOTPROTO=none\n";
	    $data .= "IPV6INIT=yes\n";
	    if ($d->{ip6} eq 'auto') {
		$data .= "IPV6_AUTOCONF=yes\n";
	    } else {
		$data .= "IPV6_AUTOCONF=no\n";
	    }
	    if ($d->{ip6} eq 'dhcp') {
		$data .= "DHCPV6C=yes\n";
	    } else {
		$data .= "IPV6ADDR=$d->{ip6}\n";
		if (defined($d->{gw6})) {
		    $data .= "IPV6_DEFAULTGW=$d->{gw6}\n";
		}
	    }
	    $self->ct_file_set_contents($filename, $data);
	    if (!PVE::Network::is_ip_in_cidr($d->{gw6}, $d->{ip6}, 6)) {
		$routes .= "$d->{gw6} dev $d->{name}\n";
		$routes .= "default via $d->{gw6}\n";
	    }
	}

	# To keep user-defined routes in route-$iface we mark ours:
	my $head = "# --- BEGIN PVE ROUTES ---\n";
	my $tail = "# --- END PVE ROUTES ---\n";
	$routes = $head . $routes . $tail if $routes;
	if ($self->ct_file_exists($routefile)) {
	    # if it exists we update by first removing our old rules
	    my $old = $self->ct_file_get_contents($routefile);
	    $old =~ s/(?:^|(?<=\n))\Q$head\E.*\Q$tail\E//gs;
	    chomp $old;
	    if ($old) {
		$self->ct_file_set_contents($routefile, $routes . $old . "\n");
	    } else {
		# or delete if we aren't adding routes and the file's now empty
		$self->ct_unlink($routefile);
	    }
	} elsif ($routes) {
	    $self->ct_file_set_contents($routefile, $routes);
	}
    }
}

1;
