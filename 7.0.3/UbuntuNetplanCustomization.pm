################################################################################
#  Copyright (c) 2018-2023 VMware, Inc.  All rights reserved.
################################################################################

package UbuntuNetplanCustomization;

# Inherit from Ubuntu17Customization.
use base qw(Ubuntu17Customization);

use strict;
use Debug;

my $UBUNTURELEASEFILE = "/etc/lsb-release";

my $NETPLANBYNETWORKMANAGERFILE = "/etc/netplan/01-network-manager-all.yaml";
my $NETPLANFILE = "/etc/netplan/99-netcfg-vmware.yaml";
# PR 2313336, put to be disabled yaml in this configuation file
my $NETPLANCFGFILE = "/etc/netplan/netplan-vmware.cfg";
# All possible Netplan Yaml configuation directories according to
# http://manpages.ubuntu.com/manpages/disco/man5/netplan.5.html
my @NETPLANDIRS = ("/run/netplan", "/etc/netplan", "/lib/netplan");

#...............................................................................
#
# DetectDistroFlavour
#
#     Detects the flavour of the distribution.
#     Called by parent class DetectDistro method.
# Params:
#     None
#
# Result:
#     Returns the distribution flavour if the distro is supported by
#     the customization object, otherwise undef.
#
#...............................................................................

sub DetectDistroFlavour
{
   my ($self) = @_;
   my $result = undef;

   if (-e $Customization::ISSUEFILE) {
      DEBUG("Reading issue file ... ");
      my $issueContent = Utils::ExecuteCommand("cat $Customization::ISSUEFILE");
      DEBUG($issueContent);

      # Ubuntu19.04 can also use the same code in this module
      # Ubuntu19.10 removes 'ifupdown', new module is extended from this one.
      if ($issueContent =~ /Ubuntu\s+(17\.10|18\.(04|10)|19\.04)/i) {
         $result = "Ubuntu $1";
      }
   } else {
      WARN("Issue file not available. Ignoring it.");
   }
   # beta versions has /etc/issue file contents of form
   # Ubuntu Trusty Tahr (development branch) \n \l
   if(! defined $result) {
      if (-e $UBUNTURELEASEFILE) {
         my $lsbContent = Utils::ExecuteCommand("cat $UBUNTURELEASEFILE");
         if ($lsbContent =~ /DISTRIB_ID=Ubuntu/i and
             $lsbContent =~ /DISTRIB_RELEASE=(17\.10|18\.(04|10)|19\.04)/) {
            $result = "Ubuntu $1";
         }
      }
   }

   return $result;
}

#...............................................................................
#
# DetectDistro
#
#     Detects the distros that should use the customization code in this module
#
# Params:
#     None
#
# Result:
#     Returns
#        the distro Id if the customization code in this module should be
#           used for that distro.
#        undef otherwise.
#
#...............................................................................

sub DetectDistro
{
   my ($self) = @_;

   my $result = $self->DetectDistroFlavour();
   if ($result) {
      if (-e $NETPLANBYNETWORKMANAGERFILE) {
         # Mixing systemd-networkd with the NetworkManager in
         # netplan settings are problematic. Simplify our life
         # by having just one single network management service.
         # Experiments show that the network manager is not really disabled
         # even its corresponding netplan file is removed.
         # If network manager is being used by the netplan,
         # then keep that way and customize the /etc/network/interfaces file.
         return undef;
      }
   }

   return $result;
}

#...............................................................................
#
# AppendYaml
#
#     Helper function to construct a Yaml.
#
# Params:
#     @yaml                 lines of the yaml content being constructed.
#     $level                indentation level.
#     $text                 a new line content.
#
# Result:
#     None.
#
#...............................................................................

sub AppendYaml
{
   my ($yaml, $level, $text) = @_;
   push(@$yaml, "  " x $level . $text . "\n");
}

#...............................................................................
#
# DisableYaml
#
#     Helper function to disable netplan yaml files in the configuration.
#
# Params:
#     $yamlFilesInCfg       yaml files in configuation file.
#
# Result:
#     None.
#
#...............................................................................
sub DisableYaml
{
   my ($self, $yamlFilesInCfg) = @_;

   my @yamlsToBeDisabled = map {Utils::Trim($_)} split(/,/, $yamlFilesInCfg);
   foreach my $netplanDir (@NETPLANDIRS) {
      if (-e $netplanDir and -d $netplanDir) {
         foreach my $yamlToBeDisabled (@yamlsToBeDisabled) {
            # in case yaml to be disabled contains wildcard
            my $yamlFilesPattern = $netplanDir . '/' . $yamlToBeDisabled;
            foreach my $yamlFile (glob($yamlFilesPattern)) {
               if (-e $yamlFile) {
                  DEBUG("Renaming $yamlFile");
                  Utils::ExecuteCommand(
                     "mv $yamlFile $yamlFile.'DisabledByVMwareCustomization'");
               }
            }
         }
      }
   }
}

#...............................................................................
#
# GetNetplanVer
#
#   Get the version of installed netplan.io pkg.
#
# Params:
#   None.
#
# Result:
#    Returns
#       version number, if the version of installed netplan.io pkg is valid,
#                       which is a number.
#       0, if getting version command fails or the version is invalid, which is
#          not a number.
#
#...............................................................................
sub GetNetplanVer
{
   my ($self) = @_;

   my $cmd = "dpkg-query --show --showformat '\${Version}' netplan.io";
   my $retCode;
   my $netplanVer = Utils::ExecuteCommand("$cmd",
      "Get netplan version installed...", \$retCode);
   if ($retCode == 0) {
      INFO("Netplan version is $netplanVer");
      if ($netplanVer =~ /^\d*\.\d*/i) {
         return $netplanVer;
      } else {
         WARN("Netplan version is invalid");
      }
   } else {
      WARN("Can not get netplan version");
   }
   return 0;
}

#...............................................................................
#
# CustomizeNICS
#
#   Customize network interface.
#   Ubuntu17 and future distros use the netplan based network configuration.
#   man (5) netplan.
#   Configuration of /etc/network/interfaces is no longer used except for
#   the local loop back interface.
#
# Params & Result:
#   None
#
#...............................................................................

sub CustomizeNICS
{
   my ($self) = @_;

   # get information on the NICS to configure
   my $nicsToConfigure = $self->{_customizationConfig}->Lookup("NIC-CONFIG|NICS");

   # split the string by ","
   my @nics = split(/,/, $nicsToConfigure);

   if (not @nics) {
      return;
   }

   # disable existing yaml entirely if any set in the configuration file
   if (-e $NETPLANCFGFILE) {
      my $yamlFilesInCfg = Utils::GetValueFromFile(
         $NETPLANCFGFILE, 'disable_netplan_yaml[\s\t]*=[\s\t]*(.*)');
      if (defined $yamlFilesInCfg) {
         DEBUG("Yaml files to be disabled: $yamlFilesInCfg");
         $self->DisableYaml($yamlFilesInCfg);
      }
   }

   # backup existing yaml before customization
   $self->CreateExistingYamlBackup();

   INFO("Customizing NICS. { $nicsToConfigure }");

   $self->{_netplan} = [];

   AppendYaml($self->{_netplan}, 0,
              "# Generated by VMWare customization engine.");
   AppendYaml($self->{_netplan}, 0, "network:");
   AppendYaml($self->{_netplan}, 1, "version: 2");
   AppendYaml($self->{_netplan}, 1, "renderer: networkd");
   AppendYaml($self->{_netplan}, 1, "ethernets:");

   # check if below netplan features are supported by the installed netplan.io
   $self->{_netplanSupportDnsFromDhcp} = 0;
   $self->{_netplanSupportDefaultRouting} = 0;
   my $netplanVer = $self->GetNetplanVer();
   if ($netplanVer) {
      $self->CheckIfNetplanSupportDnsFromDhcp($netplanVer);
      $self->CheckIfNetplanSupportDefaultRouting($netplanVer);
   }

   # iterate through each NIC
   foreach my $nic (@nics) {
      INFO("Customizing NIC $nic");
      $self->CustomizeSpecificNIC($nic);
   }

   # Drop our yaml file under /etc/netplan, as long as the file name
   # is lexicographically later than other files in the directory, it
   # shall amend and override previous ones. This saves us the effort
   # of parsing the old files. Instead of replacing lines in old files,
   # we can create a new one and modify the settings in the new file
   # without touching the ones provided by the system and the users.

   Utils::WriteBufferToFile($NETPLANFILE, $self->{_netplan});
   Utils::SetPermission($NETPLANFILE, $Utils::RWRR);

   # We need to restart the network explicitly because there is no deterministic
   # order about when the guest customization was run by the toolsd vs.
   # when the system loads the netplan setting and start the network.

   $self->RestartNetwork();
}

#...............................................................................
#
# CountBits
#
#   Count the number of one bits set in a byte.
#
# Params:
#   $value  a byte value.
#
# Result:
#   The number of one bits set.
#
#...............................................................................

sub CountBits
{
   my ($value) = @_;
   if ($value < 0 || $value > 255) {
      die "Input $value is out of range.";
   }

   $value -= ($value >> 1) & 0x55; # 0101 0101
   $value = ($value & 0x33) + (($value >> 2) & 0x33); # 0011 0011
   $value = ($value + ($value >> 4)) & 0x0f;

   return $value;
}

#...............................................................................
#
# GetIpv4Address
#
#   Get the IP v4 address/netmask format string to set in netplan yaml.
#   Note that our spec only supports one IP v4 address per NIC.
#   This is why we are returning a scalar.
#
# Params:
#   $nic    The associated network card.
#
# Result:
#   A netplan formatted IP/netmask address.
#
#...............................................................................

sub GetIpv4Address
{
   my ($self, $nic) = @_;

   my $ipaddr      = $self->{_customizationConfig}->Lookup($nic . "|IPADDR");
   my $netmask     = $self->{_customizationConfig}->Lookup($nic . "|NETMASK");

   if (!$ipaddr) {
      return undef;
   }

   my @parts = split(/\./, $netmask);
   my $len = 0;
   for my $part (@parts) {
      $len += CountBits($part);
   }

   return $ipaddr . "/" . $len;
}

#...............................................................................
#
# GetIpv6Addresses
#
#   Get the IP v6 address/netmask format strings to set in netplan yaml.
#   Note that our spec supporst multiple IP v6 addresses per NIC.
#   This is why we are returning an array.
#
# Params:
#   $nic    The associated network card.
#
# Result:
#   An array of netplan formatted IP/netmask addresses.
#
#...............................................................................

sub GetIpv6Addresses
{
   my ($self, $nic) = @_;

   my @ipv6Addresses = ConfigFile::ConvertToIndexedArray(
      $self->{_customizationConfig}->Query("^($nic\\|IPv6ADDR\\|)"));

   my @ipv6Netmasks = ConfigFile::ConvertToIndexedArray(
      $self->{_customizationConfig}->Query("^($nic\\|IPv6NETMASK\\|)"));

   my @ipv6Settings = ConfigFile::Transpose(\@ipv6Addresses, \@ipv6Netmasks);

   my @addresses;
   for my $setting (@ipv6Settings) {
      push(@addresses, $setting->[0] . "/" . $setting->[1]);
   }

   return @addresses;
}


#...............................................................................
#
# CustomizeSpecificNIC
#
#   Generate netplan specifics for a network card.
#   Ubuntu17 and future distros use the netplan based network configuration.
#   man (5) netplan.
#   Configuration of /etc/network/interfaces is no longer used except for
#   the local loop back interface.
#
#   Unlike /etc/network/interfaces, netplan supports only one Ipv4 gateway,
#   and one Ipv6 gateway, and requires the DNS setting in each NIC section.
#
# Params
#   $nic     The associated network card.
#
# Result:
#   None.
#
#...............................................................................

sub CustomizeSpecificNIC
{
   my ($self, $nic) = @_;

   # get the params
   my $macaddr     = $self->{_customizationConfig}->Lookup($nic . "|MACADDR");
   my $bootproto   = $self->{_customizationConfig}->Lookup($nic . "|BOOTPROTO");
   my $dnsfromdhcp   = $self->{_customizationConfig}->Lookup("DNS|DNSFROMDHCP");

   # get the network suffix
   my $interface = $self->GetInterfaceByMacAddress($macaddr);

   if (!$interface) {
      die "Error finding the specified NIC for MAC address = $macaddr";
   };

   INFO ("NIC suffix = $interface");

   # pr 2313336, remove old static ip of the interface from all existing
   # netplan yaml files
   $self->RemoveStaticIpFromExistingYaml($interface);

   AppendYaml($self->{_netplan}, 2, $interface . ":");

   if ($bootproto =~ /dhcp/i) {
      # check if netplan installed support dnsdhcp override
      AppendYaml($self->{_netplan}, 3, "dhcp4: yes");
      if ($self->{_netplanSupportDnsFromDhcp}) {
         DEBUG("netplan.io support DNSFROMDHCP, setting dns ipv4 override...");
         AppendYaml($self->{_netplan}, 3, "dhcp4-overrides:");
         if ($dnsfromdhcp =~ /yes/i) {
            AppendYaml($self->{_netplan}, 4, "use-dns: true");
         } else {
            AppendYaml($self->{_netplan}, 4, "use-dns: false");
         }
      }
      AppendYaml($self->{_netplan}, 3, "dhcp6: yes");
      if ($self->{_netplanSupportDnsFromDhcp}) {
         DEBUG("netplan.io support DNSFROMDHCP, setting dns ipv6 override...");
         AppendYaml($self->{_netplan}, 3, "dhcp6-overrides:");
         if ($dnsfromdhcp =~ /yes/i) {
            AppendYaml($self->{_netplan}, 4, "use-dns: true");
         } else {
            AppendYaml($self->{_netplan}, 4, "use-dns: false");
         }
      }
   } else {
      AppendYaml($self->{_netplan}, 3, "dhcp4: no");
      AppendYaml($self->{_netplan}, 3, "dhcp6: no");
   }

   my @addresses;

   my $ipv4 = $self->GetIpv4Address($nic);
   if ($ipv4) {
      push(@addresses, $ipv4);
   }

   my @ipv6s = $self->GetIpv6Addresses($nic);

   push(@addresses, @ipv6s);

   if (@addresses) {
      AppendYaml($self->{_netplan}, 3, "addresses:");
      foreach my $addr (@addresses) {
         AppendYaml($self->{_netplan}, 4, "- " . $addr);
      }
   }

   my @ipv4Gateways =
      split(/,/, $self->{_customizationConfig}->Lookup($nic . "|GATEWAY"));

   if (@ipv4Gateways) {
      $self->AddRouteIPv4($interface, \@ipv4Gateways, $nic);
   }

   my @ipv6Gateways =
      ConfigFile::ConvertToArray(
         $self->{_customizationConfig}->Query("^$nic(\\|IPv6GATEWAY\\|)"));

   if (@ipv6Gateways) {
      $self->AddRouteIPv6($interface, \@ipv6Gateways);
   }

   # name servers
   my $dnsSuffices = $self->{_customizationConfig}->GetDNSSuffixes();
   my $dnsNameservers = $self->{_customizationConfig}->GetNameServers();

   if ($dnsSuffices && @$dnsSuffices || $dnsNameservers && @$dnsNameservers) {
      AppendYaml($self->{_netplan}, 3, "nameservers:");
   }

   if ($dnsSuffices && @$dnsSuffices) {
      AppendYaml($self->{_netplan}, 4, "search:");
      foreach my $suffix (@$dnsSuffices) {
         AppendYaml($self->{_netplan}, 5, "- " . $suffix);
      }
   }

   if ($dnsNameservers && @$dnsNameservers) {
      AppendYaml($self->{_netplan}, 4, "addresses:");
      foreach my $addr (@$dnsNameservers) {
         AppendYaml($self->{_netplan}, 5, "- " . $addr);
      }
   }
}

#...............................................................................
#
# CustomizeResolvFile
#
#     Skip the change to /etc/resolv.conf since the DNS settings are
#     already customized in /etc/netplan.
#
#     DNS is loaded by the systemd-resolved. Do not update /etc/resolv.conf
#     since systemd-resolved expose a stub resolver like 127.0.0.53 which
#     is not the real DNS servers. The real DNS servers can be checked
#     with "systemd-resolve --status"" command. They are pushed to
#     /run/systemd/resolve/resolv.conf by netplan and get picked up
#     by the systemd-resolved.
#
# Params & Result:
#     None.
#
#...............................................................................

sub CustomizeResolvFile
{
   INFO("Leave $Customization::RESOLVFILE unchanged.");
}

#...............................................................................
# See Customization.pm#RestartNetwork
#...............................................................................

sub RestartNetwork
{
   my ($self) = @_;
   my $ret;

   # Once the yaml file is dropped in /etc/netplan, systemctl restart
   # systemd-networkd would not pick up the new change because
   # systemd-networkd restart command only look for a network file under
   # /run directory. A reboot would reload that file with the change.
   # However, we should avoid a reboot. Use the netplan apply command to
   # apply the configuration change without a reboot. The netplan command
   # would update the files under /run/systemd/network and restart
   # systemd-networkd.

   Utils::ExecuteCommand('/usr/sbin/netplan apply 2>&1',
                         'Apply Netplan Settings',
                         \$ret);
   if ($ret) {
      die "Failed to apply netplan settings, return code: $ret";
   }
}

sub AddRouteIPv4
{
   my ($self, $interface, $ipv4Gateways, $nic) = @_;

   my $primaryNic = $self->{_customizationConfig}->GetPrimaryNic();
   if (defined $primaryNic) {
      # This code will not be called for DHCP primary NIC, since Gateways will
      # be empty.
      if ($primaryNic ne $nic) {
         INFO("Skipping default gateway for non-primary NIC '$nic'.");
         return 0;
      } else {
         INFO("Configuring gateway from the primary NIC '$nic'.");
         # netplan does not support multiple gateways
         # multiple gateways are problematic anyway and customers
         # should be advised to use a single gateway.
         my $primaryNicGw = @$ipv4Gateways[0];
         if ($self->{_netplanSupportDefaultRouting}) {
             AppendYaml($self->{_netplan}, 3, "routes:");
             AppendYaml($self->{_netplan}, 4, "- to: default");
             AppendYaml($self->{_netplan}, 4, "  via: " . $primaryNicGw);
         } else {
             AppendYaml($self->{_netplan}, 3, "gateway4: " . $primaryNicGw);
         }
         return 0;
      }
   } else {
      INFO("No primary NIC defined.");
   }
   INFO("Configuring ipv4 route (gateway settings) for $interface.");
   my $nonPrimaryNicGw = @$ipv4Gateways[0];
   if ($self->{_netplanSupportDefaultRouting}) {
       AppendYaml($self->{_netplan}, 3, "routes:");
       AppendYaml($self->{_netplan}, 4, "- to: default");
       AppendYaml($self->{_netplan}, 4, "  via: " . $nonPrimaryNicGw);
   } else {
       AppendYaml($self->{_netplan}, 3, "gateway4: " . $nonPrimaryNicGw);
   }
}

sub AddRouteIPv6
{
   my ($self, $interface, $ipv6Gateways, $nic) = @_;

   INFO("Configuring ipv6 route (gateway settings) for $interface.");
   # netplan does not support multiple gateways
   # multiple gateways are problematic anyway and customers
   # should be advised to use a single gateway.
   if ($self->{_netplanSupportDefaultRouting}) {
       AppendYaml($self->{_netplan}, 3, "routes:");
       AppendYaml($self->{_netplan}, 4, "- to: default");
       AppendYaml($self->{_netplan}, 4, "  via: " . @$ipv6Gateways[0]);
   } else {
       AppendYaml($self->{_netplan}, 3, "gateway6: " . @$ipv6Gateways[0]);
   }
}

#...............................................................................
#
# RemoveStaticIpFromExistingYaml
#
#   Remove existing static IP from any existing netplan yaml. The reason to do
#   this is as below.
#
#   According to netplan doc, if you have two yaml files with the same
#   key/setting, the following rules apply:
#   https://github.com/CanonicalLtd/netplan/blob/master/doc/netplan-generate.md
#   1. If the values are YAML boolean or scalar values (numbers and strings),
#      the old value is overwritten by the new value.
#   2. If the values are sequences, the sequences are concatenated, the new
#      values are appended to the old list.
#   3. If the values are mappings, netplan will examine the elements of the
#      mappings in turn using these rules.
#
#   Static IP address value is sequence, so that new static IP from
#   customization spec and old static IP in any existing Yaml file for the
#   same NIC will be concatenated, the new static IP is appended to the old
#   static IP. And netplan supports multiple static IP addresses for a single
#   nic, so that both new and old static IP addresses are set to a NIC after
#   customization. This leads to ip address conflict issue.
#
# Params:
#   $interface     The network interface name
#
# Result:
#    The static ip addresses under the $interface are removed.
#
#...............................................................................

sub RemoveStaticIpFromExistingYaml
{
   my ($self, $interface) = @_;

   foreach my $netplanDir (@NETPLANDIRS) {
      my $yamlFilesPattern = $netplanDir . '/*.yaml';
      foreach my $yamlFile (glob($yamlFilesPattern)) {
         if (-e $yamlFile) {
            $self->RemoveSpecificNICStaticIpFromYaml($yamlFile, $interface);
         }
      }
   }
}

#...............................................................................
#
# CreateExistingYamlBackup
#
#   Create a backup for existing netplan yaml.
#
# Params:
#   None.
#
# Result:
#    Any existing netplan yaml files are saved to backup.
#
#...............................................................................

sub CreateExistingYamlBackup
{
   my ($self) = @_;

   foreach my $netplanDir (@NETPLANDIRS) {
      my $yamlFilesPattern = $netplanDir . '/*.yaml';
      foreach my $yamlFile (glob($yamlFilesPattern)) {
         if (-e $yamlFile) {
            Utils::ExecuteCommand(
               "$Utils::CP -f $yamlFile $yamlFile.BeforeVMwareCustomization");
         }
      }
   }
}

#...............................................................................
#
# RemoveSpecificNICStaticIpFromYaml
#
#   Read the yaml file to a buffer and write buffer content back to the file
#   except static ip addresses of the interface.
#   The static ip address node is child of interface node, the interface node
#   is child of ethernets device type node.
#   See an example from https://netplan.io/examples:
#
#   network:
#     version: 2
#     renderer: networkd
#     ethernets:
#       enp3s0:
#        addresses:
#          - 10.10.10.2/24
#        gateway4: 10.10.10.1
#        nameservers:
#            search: [mydomain, otherdomain]
#            addresses: [10.10.10.1, 1.1.1.1]
#
#    From the above example, the static ip address node is 'addresses:' under
#    the interface node 'enp3s0:', and static ip address node could be multiple
#    lines which include multiple ipv4 or ipv6 ip addresses.
#    Please note the 'addresses: [10.10.10.1, 1.1.1.1]' under 'nameservers'
#    node is DNS server addresses node, it should NOT be removed.
#
#    YAML has basic structure rules, see https://yaml.org/spec/1.2/spec.html
#    1. In YAML block styles, structure is determined by indentation.
#       In general, indentation is defined as a zero or more space characters
#       at the start of a line.
#    2. To maintain portability, tab characters must not be used in indentation
#    3. Each node must be indented further than its parent node.
#    4. All sibling nodes must use the exact same indentation level.
#
# Params:
#   $yamlFile     An existing netplan yaml file.
#   $interface    The network interface name
#
# Result:
#    The static ip addresses under the $interface are removed in netplan yaml
#    file $yamlFile.
#
#...............................................................................

sub RemoveSpecificNICStaticIpFromYaml
{
   my ($self, $yamlFile, $interface) = @_;

   DEBUG("Checking if $interface has static ip set in $yamlFile");
   my @content = Utils::ReadFileIntoBuffer($yamlFile);
   my @newContent = ();
   my $line;
   # current line indentation
   my $lineIndent;
   # ethernets node indentation
   my $ethernetsNodeIndent = 0;
   # interface node indentation
   my $interfaceNodeIndent = 0;
   # interface child node indentation
   my $interfaceChildNodeIndent = 0;
   # flag indicates if a line is ethernets node or ethernets's descendant node
   my $ethernetsFlag = 0;
   # flag indicates if a line is interface node or interface's descendant node
   my $interfaceFlag = 0;
   # flag indicates if a line is static ip address node
   my $staticIpAddressFlag = 0;

   # give each line 3 flags. For a line, if all of 3 flags are true, then this
   # line belongs to static ip address node, it should be removed.
   foreach my $rawLine (@content) {
      $line = Utils::GetLineWithoutComments($rawLine);
      if ($line =~ /^\s*$/) {
         # write empty line back directly
         push(@newContent, $rawLine);
         next;
      }
      # save current line indentation
      if ($line =~ /^(\s*)\S/) {
         $lineIndent = length($1);
      }

      # ethernets node and it's descendant nodes begins at 'ethernets:' and
      # ends at ethernets' sibling node which has same indentation
      if ($line =~ /^\s+ethernets:/i) {
         # current line is ethernets node
         # save ethernets node indentation
         $ethernetsNodeIndent = $lineIndent;
         $ethernetsFlag = 1;
         # write 'ethernets:' line back directly
         push(@newContent, $rawLine);
         next;
      } elsif ($lineIndent eq $ethernetsNodeIndent) {
         # when current line indentation is same with ethernets node
         # indentation again, means it's ethernets's sibling node
         $ethernetsFlag = 0;
      }

      # a line has interfaceFlag must be a line has ethernetsFlag
      if ($ethernetsFlag) {
         # interface node and it's descendant nodes begins at '$interface:' and
         # ends at interface' sibling node which has same indentation
         if ($line =~ /^\s+$interface:/) {
            # current line is interface node
            # save interface node indentation
            $interfaceNodeIndent = $lineIndent;
            $interfaceFlag = 1;
            # write '$interface:' line back directly
            push(@newContent, $rawLine);
            next;
         } elsif ($lineIndent eq $interfaceNodeIndent) {
            # when current line indentation is same with interface node
            # indentation again, means it's interface's sibling node
            $interfaceFlag = 0;
         }
         # a line has staticIpAddressFlag must be a line has interfaceFlag
         if ($interfaceFlag) {
            # save the first interface child node indentation which indentation
            # is more than the interface node's
            if (($lineIndent gt $interfaceNodeIndent) &&
                (not $interfaceChildNodeIndent)) {
               $interfaceChildNodeIndent = $lineIndent;
            }
            # all interface's child nodes should have the same indentation
            if ($lineIndent eq $interfaceChildNodeIndent) {
               if ($line =~ /^\s+addresses:/i) {
                  # current line is static ip address node
                  $staticIpAddressFlag = 1;
               } elsif ($line =~ /^\s+[\w-]+:/) {
                  # current line is static ip address node's sibling node
                  $staticIpAddressFlag = 0;
               }
            }
         }
      }
      if ($ethernetsFlag && $interfaceFlag && $staticIpAddressFlag) {
         DEBUG("Removing static ip address line: $rawLine");
      } else {
         push(@newContent, $rawLine);
      }
   }
   Utils::WriteBufferToFile($yamlFile, \@newContent);
}

#...............................................................................
#
# CheckIfNetplanSupportDnsFromDhcp
#
#   Check if the installed netplan.io pkg supports DNSFROMDHCP by comparing its
#   version with 0.96.
#
# Params:
#   @netplanVer   The version number of installed netplan.io pkg
#
# Result:
#   Set _netplanSupportDnsFromDhcp to 1 if the version of installed netplan.io
#   pkg >= 0.96.
#   Set _netplanSupportDnsFromDhcp to 0 if the version of installed netplan.io
#   pkg < 0.96.
#
#...............................................................................
sub CheckIfNetplanSupportDnsFromDhcp
{
   my ($self, $netplanVer) = @_;
   my $cmd = "dpkg --compare-versions $netplanVer ge 0.96";
   my $retCode;
   Utils::ExecuteCommand("$cmd",
      "Checking if netplan>=0.96...", \$retCode);
   if ($retCode == 0) {
      # "netplan.io" pkg is installed and its ver>=0.96
      $self->{_netplanSupportDnsFromDhcp} = 1;
   } else {
      # "netplan.io" pkg is installed but its ver<0.96
      $self->{_netplanSupportDnsFromDhcp} = 0;
   }
}

#...............................................................................
#
# CheckIfNetplanSupportDefaultRouting
#
#   Check if the installed netplan.io pkg supports default routing by comparing
#   its version with 0.103.
#
# Params:
#   @netplanVer   The version number of installed netplan.io pkg
#
# Result:
#   Set _netplanSupportDefaultRouting to 1 if the version of installed
#   netplan.io pkg >= 0.103.
#   Set _netplanSupportDefaultRouting to 0 if the version of installed
#   netplan.io pkg < 0.103.
#
#...............................................................................
sub CheckIfNetplanSupportDefaultRouting
{
   my ($self, $netplanVer) = @_;
   my $cmd = "dpkg --compare-versions $netplanVer ge 0.103";
   my $retCode;
   Utils::ExecuteCommand("$cmd",
      "Checking if netplan>=0.103...", \$retCode);
   if ($retCode == 0) {
      # "netplan.io" pkg is installed and its ver>=0.103
      $self->{_netplanSupportDefaultRouting} = 1;
   } else {
      # "netplan.io" pkg is installed but its ver<0.103
      $self->{_netplanSupportDefaultRouting} = 0;
   }
}

1;
