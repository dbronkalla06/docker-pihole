#!/usr/bin/with-contenv perl

use 5.010;
use strict;
use warnings;
no warnings "experimental";

use Carp qw(carp croak);
use Data::Dumper;
use File::Find;

###############################################################################

{   package Cvar;

    sub env ($$;\%) {
        my ($class, $name, %env) = @_;
        %env = %ENV unless %env;

        return bless {
            _type => "env",
            _name => $name,
            _env  => \%env
        }, $class;
    }

    sub lit ($$$) {
        my ($class, $val) = @_;

        return bless {
            _type => "lit",
            _val  => $val
        }, $class;
    }

    sub name {
        my $self = shift;
        return ($self->{_type} eq "env") ?
            $self->{_name} :
            undef;
    }

    sub val {
        my $self = shift;
        return ($self->{_type} eq "env") ?
            $self->{_env}{$self->{_name}} :
            $self->{_val};
    }

    sub is_defined {
        my $self = shift;
        return defined($self->val());
    }
}

###############################################################################

my $PIHOLE_CONF  = "/etc/pihole/setupVars.conf";
my $FTL_CONF     = "/etc/pihole/pihole-FTL.conf";
my $DNSMASQ_CONF = "/etc/dnsmasq.d/01-pihole.conf";

sub env ($;\%)  { return Cvar->env(@_); }
sub lit ($)     { return Cvar->lit(@_); }

sub configure ($$$$@);
sub configure_admin_email ($);
sub configure_blocklists ();
sub configure_dns_defaults;
sub configure_dns_hostname ($$@);
sub configure_dns_interface ($$);
sub configure_dns_user ($);
sub configure_ftl ($$$@);
sub configure_network (\%$$);
sub configure_pihole ($$$@);
sub configure_temperature ($);
sub configure_web_address ($$$);
sub configure_web_fastcgi ($$);
sub configure_web_password ($$);
sub configure_whitelists ();
sub do_or_die (@);
sub explain (@);
sub fix_capabilities ($);
sub fix_permissions ($);
sub mask ($$);
sub print_env(\%);
sub read_file ($);
sub sed (&$@);
sub set_defaults (\%);
sub test_configuration ($);
sub trim ($);
sub validate ($$$@);
sub validate_ip ($);
sub write_file ($@);


###############################################################################

sub configure ($$$$@) {
    my $path  = shift;
    my $name  = shift; # Variable name written to output
    my $reqd  = shift;
    my $cvar  = shift;
    my @allow = @_;

    validate($name, $reqd, $cvar, @allow);

    my @cfg = grep {!/^$name=/} read_file($path);
    push @cfg, "$name=" . ($cvar->val() // "");
    chomp @cfg;

    write_file($path, join("\n", @cfg)."\n");
    rename($PIHOLE_CONF.".new", $PIHOLE_CONF);
}

sub configure_admin_email ($) {
    my ($email) = @_;
    do_or_die("pihole", "-a", "-e", $email->val()) if $email->is_defined();
}

sub configure_blocklists () {
    my $path = "/etc/pihole/adlists.list";
    return if -f $path;

    my @items = ();
    push @items, "https://dbl.oisd.nl/\n";
    write_file($path, @items);
}

sub configure_dns_defaults {
    do_or_die("cp", "/etc/.pihole/advanced/01-pihole.conf", $DNSMASQ_CONF) if !-f $DNSMASQ_CONF;
}

sub configure_dns_hostname ($$@) {
    my $ipv4 = shift;
    my $ipv6 = shift;
    my @names = @_;

    my @cfg = read_file($DNSMASQ_CONF);
    #cfg = grep {!/^(#|\s*$)/} @cfg;
    @cfg = grep {!/^server=/}  @cfg;

    # TODO

    write_file($DNSMASQ_CONF, @cfg);
}

sub configure_dns_interface ($$) {
    my ($iface, $listen) = @_;

    my @cfg = read_file($DNSMASQ_CONF);
    #cfg = grep {!/^(#|\s*$)/}   @cfg;
    @cfg = grep {!/^interface=/} @cfg;

    # TODO

    write_file($DNSMASQ_CONF, @cfg);
}

sub configure_dns_user ($) {
    my ($dns_user) = @_;

    # Erase any user= directives in config snippet files
    find(sub {
        write_file($_, grep {!/^user=/} read_file($_)) if -f;
    }, "/etc/dnsmasq.d");

    configure("/etc/dnsmasq.conf", "user", 1, $dns_user);
}

sub configure_ftl ($$$@) {
    return &configure($FTL_CONF, @_);
}

sub configure_network (\%$$) {
    my ($env, $ipv4, $ipv6) = @_;
    my %env = %{$env};

    if (!defined $ipv4) {
        explain("ip route get 1.1.1.1")
            unless (my $output = `ip route get 1.1.1.1`);

        my ($gw) = $output =~ m/via\s+([^\s]+)/;
        my ($if) = $output =~ m/dev\s+([^\s]+)/;
        my ($ip) = $output =~ m/src\s+([^\s]+)/;

        $env{"PIHOLE_IPV4_ADDRESS"} = $ip;
    }

    validate_ip(env("PIHOLE_IPV4_ADDRESS"));
    configure_pihole("IPV4_ADDRESS", 1, env("PIHOLE_IPV4_ADDRESS"));

    # TODO
    if (!defined $ipv6) {
        my $output = `ip route get 2606:4700:4700::1001 2>/dev/null`
            or return;

        my ($gw) = $output =~ m/via\s+([^\s]+)/;
        my ($if) = $output =~ m/dev\s+([^\s]+)/;
        my ($ip) = $output =~ m/src\s+([^\s]+)/;

        my @output = `ip -6 addr show dev $if`
            or explain("ip -6 addr show dev $if");

        my @gua = (); # global unique addresses
        my @ula = (); # unique local addresses
        my @ll  = (); # link local addresses

        foreach (grep {/inet6/} @output) {
            my ($ip) = m{inet6\s+([^/])+/};
            my ($chazwazza) = $ip =~ /^([^:]+):/;
            $chazwazza = hex($chazwazza);

            push @ula, $ip if (($chazwazza & mask( 7, 16)) == 0xfc00);
            push @gua, $ip if (($chazwazza & mask( 3, 16)) == 0x2000);
            push @ll,  $ip if (($chazwazza & mask(10, 16)) == 0xfe80);
        }

        Dumper[@gua];
        Dumper[@ula];
        Dumper[@ll];
    }

    # validate_ip(env("PIHOLE_IPV6_ADDRESS"));
    # configure_pihole("IPV6_ADDRESS", 1, $env, "PIHOLE_IPV6_ADDRESS");
}

# Change an option in setupVars.conf
sub configure_pihole ($$$@) {
    return &configure($PIHOLE_CONF, @_);
}

sub configure_temperature ($) {
    my ($unit) = @_;
    validate("PIHOLE_TEMPERATURE_UNIT", 0, $unit, "k", "f", "c", "K", "F", "C");
    do_or_die("pihole", "-a", "-".lc($unit->val())) if $unit->is_defined();
}

sub configure_web_address ($$$) {
    my ($ipv4, $ipv6, $port) = @_;
    my $path = "/etc/lighttpd/lighttpd.conf";
    my @conf = read_file($path);

    croak sprintf("%s (%s) is invalid, must be 1-65535", $port->name(), $port->val())
        unless ($port->val() =~ /^\d+$/ and $port->val() > 0 and $port->val() <= 65535);
    @conf = sed {/^server.port\s*=/} "server.port = ".$port->val(), @conf;

    my @bind = ('server.bind = "127.0.0.1"');
    push @bind, sprintf('$SERVER["socket"] == "%s:%s" { }', $ipv4->val(), $port->val()) if $ipv4->is_defined();
    push @bind, sprintf('$SERVER["socket"] == "%s:%s" { }', $ipv6->val(), $port->val()) if $ipv6->is_defined();

    # TODO: disable use-ipv6.pl because it binds to ::
    # TODO: need to add if replace doesn't match
    @conf = grep {!/^\s*\$SERVER\["socket"/} @conf;
    @conf = sed {/^server\.bind\s*=/} \@bind, @conf;

    write_file($path, @conf);
}

sub configure_web_fastcgi ($$) {
    my ($ipv4, $host) = @_;
    my $path = "/etc/lighttpd/conf-enabled/15-fastcgi-php.conf";
    my $conf = read_file($path);

    $conf =~ s/^\s*"VIRTUAL_HOST".*$//ms;
    $conf =~ s/^\s*"ServerIP".*$//ms;
    $conf =~ s/^\s*"PHP_ERROR_LOG".*$//ms;

    my $env;
    do {
        my @x = (sprintf('"VIRTUAL_HOST"  => "%s"', $host->val()));
        push(@x, sprintf('"ServerIP"      => "%s"', $ipv4->val())) if $ipv4->is_defined();
        push(@x, sprintf('"PHP_ERROR_LOG" => "%s"', "/var/log/lighttpd/error.log"));
        $env = join(",\n\t\t\t", @x);
    };

    # TODO: sed
    $conf =~ s/^(\s*"bin-environment".*)$/$1\n\t\t\t$env,/m;

    write_file($path, $conf);
}

sub configure_web_password ($$) {
    my ($pw, $pwfile) = @_;

    if ($pwfile->is_defined() and -f $pwfile->val() and -s $pwfile->val()) {
        say "Reading web password from ".$pwfile->val();
        $pw = lit(read_file($pwfile));
        chomp $pw;
    }

    if (!$pw->is_defined()) {
        $pw = lit(trim(`openssl rand -base64 20`));
        say "Generated new random web admin password: ".$pw->val();
    }

    do_or_die("pihole", "-a", "-p", $pw->val(), $pw->val());
}

# TODO this file isn't used (yet)
sub configure_whitelists () {
    my $path = "/etc/pihole/whitelists.list";
    return if -f $path;

    my @items = ();
    push @items, "https://github.com/anudeepND/whitelist/blob/master/domains/optional-list.txt";
    push @items, "https://github.com/anudeepND/whitelist/blob/master/domains/referral-sites.txt";
    push @items, "https://github.com/anudeepND/whitelist/blob/master/domains/whitelist.txt";
    write_file($path, join("\n", @items)."\n");
}

sub do_or_die (@) {
    explain(@_) if system(@_);
}

# Explain how a call to system() failed, then abort
sub explain (@) {
    ($? == -1)  or croak join(" ", @_)." failed to execute: ".$!;
    ($? & 0x7f) or croak join(" ", @_)." died with signal ". ($? & 0x7f);
    croak join(" ", @_)." failed with exit code ".($? >> 8);
}

sub fix_capabilities ($) {
    my ($dns_user) = @_;
    my $ftl_path   = trim(`which pihole-FTL`);

    do_or_die("setcap", "CAP_SYS_NICE,CAP_NET_BIND_SERVICE,CAP_NET_RAW,CAP_NET_ADMIN+ei", $ftl_path)
        if ($dns_user ne "root");
}

sub fix_permissions ($) {
    my ($dns_user) = @_;

    # Re-apply perms from basic-install over any volume mounts that may be present (or not)
    do_or_die("mkdir", "-p",
      "/etc/pihole",
      "/var/run/pihole",
      "/var/log/pihole",
      "/var/log/lighttpd");
    do_or_die("chown", "www-data:root",
      "/etc/lighttpd",
      "/var/log/lighttpd");
    do_or_die("chown", "pihole:root",
      "/etc/pihole",
      "/var/run/pihole",
      "/var/log/pihole");
    do_or_die("chmod", "0755",
      "/etc/pihole",
      "/etc/lighttpd",
      "/var/run",
      "/var/log");

    do_or_die("touch",
      "/etc/pihole/setupVars.conf",
      "/var/log/lighttpd/access.log",
      "/var/log/lighttpd/error.log");
    do_or_die("chown", "www-data:root",
      "/var/log/lighttpd/access.log",
      "/var/log/lighttpd/error.log");

    my @files = (
      "/etc/pihole/custom.list",
      "/etc/pihole/dhcp.leases",
      "/etc/pihole/pihole-FTL.conf",
      "/etc/pihole/regex.list",
      "/etc/pihole/setupVars.conf",
      "/var/log/pihole",
      "/var/log/pihole-FTL.log",
      "/var/log/pihole.log",
      "/var/run/pihole-FTL.pid",
      "/var/run/pihole-FTL.port");

    do_or_die("touch", @files);
    do_or_die("chown", $dns_user->val().":root", @files);
    do_or_die("chmod", "0644",
      "/etc/pihole/pihole-FTL.conf",
      "/etc/pihole/regex.list",
      "/run/pihole-FTL.pid",
      "/run/pihole-FTL.port",
      "/var/log/pihole-FTL.log",
      "/var/log/pihole.log");

    do_or_die("rm", "-f",
      "/var/run/pihole/FTL.sock");

    do_or_die("cp", "-f",
        "/etc/pihole/setupVars.conf",
        "/etc/pihole/setupVars.conf.bak");
}

sub mask ($$) {
    my ($bits, $size) = @_;
    return ((1 << $bits) - 1) << ($size - $bits);
}

sub print_env(\%) {
    my %env = %{$_[0]};

    say "Environment:";
    foreach my $k (sort (keys %env)) {
        printf "  %-50s= %s\n", $k, ($env{$k} // "undef");
    }
}

sub read_file ($) {
    local @ARGV = $_[0];
    return wantarray() ?
        map { chomp; $_ } <> :
        do  { local $/;   <> };
}

sub sed (&$@) {
    my $test = shift;
    my $swap = shift;
    my @result;
    my $swappd;

    foreach $_ (@_) {
        if (&$test) {
            $swappd = (ref $swap eq "CODE") ? &$swap : $swap;

            given (ref $swappd) {
                when ("")       { push @result, $swappd;  }
                when ("ARRAY")  { push @result, @$swappd; }
                when ("SCALAR") { push @result, $$swappd; }
                default         { croak "wrong type"; }
            }
        } else {
            push @result, $_;
        }
    }

    return @result;
}

sub set_defaults (\%) {
    my ($env) = @_;

    $env->{"PIHOLE_BLOCKING_MODE"              } //= "NULL";
    $env->{"PIHOLE_TEMPERATURE_UNIT"           } //= "f";
    $env->{"PIHOLE_ADMIN_EMAIL"                } //= "root\@example.com";
    $env->{"PIHOLE_DNS_UPSTREAM_1"             } //= "1.1.1.1";
    $env->{"PIHOLE_LISTEN"                     } //= "all";
    $env->{"PIHOLE_QUERY_LOGGING"              } //= "true";
    $env->{"PIHOLE_DNS_BOGUS_PRIV"             } //= "true";
    $env->{"PIHOLE_DNS_FQDN_REQUIRED"          } //= "false";
    $env->{"PIHOLE_DNS_DNSSEC"                 } //= "false";
    $env->{"PIHOLE_DNS_CONDITIONAL_FORWARDING" } //= "false";
    $env->{"PIHOLE_WEB_HOSTNAME"               } //= trim(`hostname -f 2>/dev/null || hostname`);
    $env->{"PIHOLE_WEB_PORT",                  } //= "80";
    $env->{"PIHOLE_WEB_UI"                     } //= "boxed";
    $env->{"INSTALL_WEB_SERVER"                } //= "true";
    $env->{"INSTALL_WEB_INTERFACE"             } //= "true";
    $env->{"PIHOLE_LIGHTTPD_ENABLED"           } //= "true";
    $env->{"PIHOLE_DNS_USER"                   } //= "pihole";
}

sub test_configuration ($) {
    my ($dns_user) = @_;

    say "\n\n$PIHOLE_CONF";
    do_or_die("cat", "-n", $PIHOLE_CONF);

    say "\n\n$FTL_CONF";
    do_or_die("cat", "-n", $FTL_CONF);

    say "\n\n$DNSMASQ_CONF";
    do_or_die("cat", "-n", $DNSMASQ_CONF);

    say "\n\n/etc/dnsmasq.conf";
    do_or_die("cat", "-n", "/etc/dnsmasq.conf");

    say "\n\n/etc/lighttpd/lighttpd.conf";
    do_or_die("cat", "-n", "/etc/lighttpd/lighttpd.conf");

    say "\n\n/etc/lighttpd/conf-enabled/15-fastcgi-php.conf";
    do_or_die("cat", "-n", "/etc/lighttpd/conf-enabled/15-fastcgi-php.conf");

    # check pihole configuration
    do {
        local *STDOUT;
        my $output;
        open STDOUT, ">>", \$output;
        do_or_die("sudo", "-u", $dns_user->val(), "-E", "/usr/bin/pihole-FTL", "test");
    };

    # check lighttpd configuration
    do_or_die("lighttpd", "-t", "-f", "/etc/lighttpd/lighttpd.conf");
}

sub trim ($) {
    my ($str) = @_;
    $str =~ s/\A\s+|\s+\z//g if (defined $str);
    return $str;
}

# Enforce (non-)required and enumerated value constraints
sub validate ($$$@) {
    my $name  = shift;
    my $reqd  = shift;
    my $cvar  = shift;
    my %allow = map { $_ => 1 } @_;

    (!$cvar->is_defined() and $reqd) and
        croak(($cvar->name() // $name)." cannot be empty");

    ($cvar->is_defined() and %allow and !exists($allow{$cvar->val()})) and
        croak(($cvar->name() // $name)." cannot be ".$cvar->val()." (expected one of: ".join(", ", @_).")");
}

sub validate_ip ($) {
    my ($ip) = @_;

    if ($ip->is_defined() and system("ip route get '".$ip->val()."' 2>/dev/null")) {
        croak(sprintf("%s (%s) is invalid", $ip->name(), $ip->val()));
    }
}

sub write_file ($@) {
    my $path = shift;
    open(my $io, ">", $path) or croak "can't open $path for writing: $!";
    print $io join("\n", @_);
    print $io "\n" unless ($_[-1] =~ m/\n\z/);
    close $io;
}

###############################################################################

sub main {
    # https://github.com/pi-hole/pi-hole/blob/6b536b7428a1f57ff34ddc444ded6d3a62b00a38/automated%20install/basic-install.sh#L1474
    # installConfigs
    # TODO

    set_defaults(%ENV);
    configure_network(%ENV, env("PIHOLE_IPV4_ADDRESS"), env("PIHOLE_IPV6_ADDRESS"));
    print_env(%ENV);

    fix_capabilities(env("PIHOLE_DNS_USER"));
    fix_permissions(env("PIHOLE_DNS_USER"));

    # Update version numbers
    do_or_die("pihole", "updatechecker");

    configure_web_password(env("PIHOLE_WEB_PASSWORD"), env("PIHOLE_WEB_PASSWORD_FILE"));
    configure_web_address(env("PIHOLE_IPV4_ADDRESS"), env("PIHOLE_IPV6_ADDRESS"), env("PIHOLE_WEB_PORT"));
    configure_web_fastcgi(env("PIHOLE_IPV4_ADDRESS"), env("PIHOLE_WEB_HOSTNAME"));

    configure_dns_defaults();
    configure_dns_interface(env("PIHOLE_LISTEN"), env("PIHOLE_INTERFACE"));
    configure_dns_user(env("PIHOLE_DNS_USER"));
    configure_dns_hostname(env("PIHOLE_IPV4_ADDRESS"), env("PIHOLE_IPV6_ADDRESS"), env("PIHOLE_WEB_HOSTNAME"));

    configure_temperature(env("PIHOLE_TEMPERATURE_UNIT"));
    configure_admin_email(env("PIHOLE_ADMIN_EMAIL"));

    configure_pihole("PIHOLE_DNS_1"                  , 1, env("PIHOLE_DNS_UPSTREAM_1"));
    configure_pihole("PIHOLE_DNS_2"                  , 0, env("PIHOLE_DNS_UPSTREAM_2"));
    configure_pihole("PIHOLE_DNS_3"                  , 0, env("PIHOLE_DNS_UPSTREAM_3"));
    configure_pihole("PIHOLE_DNS_4"                  , 0, env("PIHOLE_DNS_UPSTREAM_4"));
    configure_pihole("DNSMASQ_LISTENING"             , 0, env("PIHOLE_LISTEN"),            "all", "local", "iface");
    configure_pihole("PIHOLE_INTERFACE"              , 0, env("PIHOLE_INTERFACE"));
    configure_pihole("QUERY_LOGGING"                 , 0, env("PIHOLE_QUERY_LOGGING"),     "true", "false");
    configure_pihole("INSTALL_WEB_SERVER"            , 0, env("INSTALL_WEB_SERVER"),       "true", "false");
    configure_pihole("INSTALL_WEB_INTERFACE"         , 0, env("INSTALL_WEB_INTERFACE"),    "true", "false");
    configure_pihole("LIGHTTPD_ENABLED"              , 0, env("PIHOLE_LIGHTTPD_ENABLED"),  "true", "false");
    configure_pihole("DNS_BOGUS_PRIV"                , 0, env("PIHOLE_DNS_BOGUS_PRIV"),    "true", "false");
    configure_pihole("DNS_FQDN_REQUIRED"             , 0, env("PIHOLE_DNS_FQDN_REQUIRED"), "true", "false");
    configure_pihole("DNSSEC"                        , 0, env("PIHOLE_DNS_DNSSEC"),        "true", "false");
    configure_pihole("CONDITIONAL_FORWARDING"        , 0, env("PIHOLE_DNS_CONDITIONAL_FORWARDING"), "true", "false");
    configure_pihole("CONDITIONAL_FORWARDING_IP"     , 0, env("PIHOLE_DNS_CONDITIONAL_FORWARDING_IP"));
    configure_pihole("CONDITIONAL_FORWARDING_DOMAIN" , 0, env("PIHOLE_DNS_CONDITIONAL_FORWARDING_DOMAIN"));
    configure_pihole("CONDITIONAL_FORWARDING_REVERSE", 0, env("PIHOLE_DNS_CONDITIONAL_FORWARDING_REVERSE"));
    configure_pihole("WEBUIBOXEDLAYOUT"              , 0, env("PIHOLE_WEB_UI"),            "boxed", "normal");

    # https://docs.pi-hole.net/ftldns/configfile/
    configure_ftl("BLOCKINGMODE",      1, env("PIHOLE_BLOCKING_MODE"),        "NULL", "IP-NODATA-AAAA", "IP", "NXDOMAIN", "NODATA");
    configure_ftl("SOCKET_LISTENING",  0, lit("local"),                       "local", "all");
    configure_ftl("FTLPORT",           0, lit("4711"));
    configure_ftl("RESOLVE_IPV6",      0, lit("true"),                        "true", "false");
    configure_ftl("RESOLVE_IPV4",      0, lit("true"),                        "true", "false");
    configure_ftl("DBIMPORT",          0, lit("true"),                        "true", "false");
    configure_ftl("MAXDBDAYS",         0, lit("180"));
    configure_ftl("DBINTERVAL",        0, lit("1.0"));
    #onfigure_ftl("PRIVACYLEVEL",      0, env("PIHOLE_DNS_PRIVACY_LVL"),      "0", "1", "2");
    #onfigure_ftl("CNAMEDEEPINSPECT",  1, env("PIHOLE_DNS_CNAME_INSPECT"),    "true", "false");
    #onfigure_ftl("IGNORE_LOCALHOST",  0, env("PIHOLE_DNS_IGNORE_LOCALHOST"), "true", "false");

    # https://github.com/pi-hole/pi-hole/blob/e9b039139c468798fb6d9457e4c9012171faee33/advanced/Scripts/webpage.sh#L146
    #
    # ProcessDNSSettings
    #   PIHOLE_DNS_n
    #   DNS_FQDN_REQUIRED
    #   DNS_BOGUS_PRIV
    #   DNSSEC
    #   HOSTRECORD
    #   DNSMASQ_LISTENING
    #   CONDITIONAL_FORWARDING
    #   CONDITIONAL_FORWARDING_DOMAIN
    #   CONDITIONAL_FORWARDING_REVERSE
    #   CONDITIONAL_FORWARDING_IP
    #   REV_SERVER

    configure_blocklists();
    configure_whitelists();
    test_configuration(env("PIHOLE_DNS_USER"));
}

###############################################################################

main();