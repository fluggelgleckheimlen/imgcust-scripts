#!/usr/bin/perl

###############################################################################
# Copyright (c) 2025 Broadcom. All Rights Reserved.
# Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
# and/or its subsidiaries.
###############################################################################

package SLES16Customization;
use base qw(SLES12Customization);

use strict;
use Debug;

our $OSRELEASEFILE = "/etc/os-release";
our $SLES16HOSTNAMEFILE = "/etc/hostname";
# NetworkManager releated
my $NMKEYFILEPROFILEDIR = "/etc/NetworkManager/system-connections";
my $NMKEYFILEPROFILEEXT = ".nmconnection";
my $NMKEYFILEPROFILEPREFIX = "VMware-customization-";
my $NMKEYFILEPROFILEUSERORIGIN = "VMware customization";

sub DetectDistro
{
   my ($self) = @_;

   return $self->DetectDistroFlavour();
}

sub DetectDistroFlavour
{
   my ($self) = @_;
   my $result = undef;

   if (-e $Customization::ISSUEFILE) {
      DEBUG("Reading issue file ... ");
      my $issueContent = Utils::ExecuteCommand("cat $Customization::ISSUEFILE");
      if ($issueContent =~ /suse.*enterprise.*(server|desktop).*\s+(\d+)/i) {
         if ($2 >= 16) {
            $result = "Suse Linux Enterprise $1 $2";
         }
      }
   } else {
      WARN("Issue file is not available. Ignoring it.");
   }

   if (! defined $result) {
      if (-e $OSRELEASEFILE) {
         DEBUG("Reading $OSRELEASEFILE file ... ");
         my $osReleaseContent = Utils::GetValueFromFile($OSRELEASEFILE,
            'PRETTY_NAME[\s\t]*=(.*)');
         if ($osReleaseContent =~ /suse.*enterprise.*(server|desktop).*\s+(\d+)/i) {
            if ($2 >= 16) {
               $result = "Suse Linux Enterprise $1 $2";
            }
         }
      }
   }

   return $result;
}

sub InitOldHostname
{
   my ($self) = @_;

   $self->{_oldHostName} = Utils::GetValueFromFile($SLES16HOSTNAMEFILE,
                                                   '^(?!\s*#)(.+)');
   chomp($self->{_oldHostName});
   Utils::Trim($self->{_oldHostName});

   INFO("OLD HOST NAME = $self->{_oldHostName}");
}

sub CustomizeHostName
{
   my ($self) = @_;
   my $changeHostFQDN = 0;

   my $newHostName   = $self->{_customizationConfig}->GetHostName();
   my $newDomainName = $self->{_customizationConfig}->GetDomainName();

   if (ConfigFile::IsKeepCurrentValue($newHostName)) {
      $newHostName = Utils::GetShortnameFromFQDN($self->OldHostName());
   } else {
      $changeHostFQDN = 1;
   }
   if (ConfigFile::IsKeepCurrentValue($newDomainName)) {
      $newDomainName = Utils::GetDomainnameFromFQDN($self->OldHostName());
   } else {
      $changeHostFQDN = 1;
      if (ConfigFile::IsRemoveCurrentValue($newDomainName)) {
         $newDomainName = '';
      }
   }

   if ($changeHostFQDN) {
      if (! $newHostName) {
         die 'Cannot customize domain name only because the current hostname ' .
             'is invalid.';
      }

      my $newFQDN = $newHostName;
      if ($newDomainName) {
         $newFQDN .= ".$newDomainName";
      }

      Utils::WriteBufferToFile($SLES16HOSTNAMEFILE, ["$newFQDN\n"]);
      Utils::SetPermission($SLES16HOSTNAMEFILE, $Utils::RWRR);

      Utils::ExecuteCommand("hostname $newHostName");
   }
}

#...............................................................................
#
# CustomizeNICS
#
#   Customize network interface. This is specific to SLES 16+ which customizes
#   NICS only.
#
# Params & Result:
#   None
#
# NOTE:
#...............................................................................

sub CustomizeNICS
{
   my ($self) = @_;

   # get information on the NICS to configure
   my $nicsToConfigure =
      $self->{_customizationConfig}->Lookup("NIC-CONFIG|NICS");

   # split the string by ","
   my @nics = split(/,/, $nicsToConfigure);

   INFO("Customizing NICS. { $nicsToConfigure }");

   # iterate through each NIC
   foreach my $nic (@nics) {
      INFO("Customizing NIC $nic");
      $self->CustomizeSpecificNIC($nic);
   }
}

sub CustomizeNetwork
{
   my ($self) = @_;

   $self->RemoveOldNMKeyfileProfiles();

   $self->SUPER::CustomizeNetwork();
}

#...............................................................................
#
# RemoveOldNMKeyfileProfiles
#
#   Delete old NetworkManager keyfile profiles under directory
#   /etc/NetworkManager/system-connections except lo.nmconnection.
#   lo.nmconnection is under /etc/NetworkManager/system-connnections by default,
#   keep it to preserve the user's loopback interface settings after guest
#   customization.
#
# Params:
#   None.
#
# Result:
#   None.
#
#...............................................................................

sub RemoveOldNMKeyfileProfiles
{
   my ($self) = @_;
   # NetworkManager loads files under directory
   # /etc/NetworkManager/system-connections regardless of filename.
   INFO("Removing old NetworkManager profiles except lo.nmconnection");
   my $keyfileProfilePattern = $NMKEYFILEPROFILEDIR . "/*";
   my @filesToBeDeleted = glob($keyfileProfilePattern);
   @filesToBeDeleted = grep { $_ !~ /.*\/lo\.nmconnection$/ } @filesToBeDeleted;
   Utils::DeleteFiles(@filesToBeDeleted);
}

#...............................................................................
#
# WriteNMKeyfileProfile
#
#   Write network configuration for the associated network card to the
#   NetworkManager keyfile profile.
#
# Params:
#   $nic        the associated network card
#
# Result:
#   None.
#
#...............................................................................

sub WriteNMKeyfileProfile
{
   my ($self, $nic) = @_;

   # Get the interface
   my $macaddr = $self->{_customizationConfig}->Lookup($nic . "|MACADDR");
   my $interface = $self->GetInterfaceByMacAddress($macaddr);

   if (!$interface) {
      die "Error finding the specified NIC (MAC address = $macaddr)";
   }

   INFO("Writing NetworkManager keyfile profile for NIC suffix = $interface");
   # Write the network profile in keyfile format
   my @content = $self->FormatNMKeyfileProfileContent($nic, $interface);
   unshift(@content, "# Generated by VMware customization engine.\n");
   my $keyfileProfile =
      $self->GetNMKeyfileProfilePrefix() . $interface . $NMKEYFILEPROFILEEXT;
   DEBUG("Content of Keyfile profile $keyfileProfile\n@content");
   Utils::WriteBufferToFile($keyfileProfile, \@content);
   # keyfile profile should be made readable only to root.
   Utils::SetPermission($keyfileProfile, $Utils::RW00);
}

sub CustomizeSpecificNIC
{
   my ($self, $nic) = @_;

   # Write network configuration to NetworkManager keyfile profile
   # wicked has been removed
   $self->WriteNMKeyfileProfile($nic);
}

#...............................................................................
#
# GetNMKeyfileProfilePrefix
#
#
# Params:
#   None.
#
# Result:
#   Return a prefix (without the interface and extension) of the path to a
#   keyfile profile created by VMware customization engine.
#
#...............................................................................

sub GetNMKeyfileProfilePrefix
{
   my ($self) = @_;

   return $NMKEYFILEPROFILEDIR . "/" . $NMKEYFILEPROFILEPREFIX;
}

#...............................................................................
#
# FormatNMKeyfileProfileContent
#
#   Formats the content of the NetworkManager keyfile profile.
#   A NetworkManager property is stored in the keyfile as a variable of the same
#   name and in the same format. There are several exceptions to this rule,
#   mainly for making keyfile syntax easier for humans.
#   man (5) nm-settings
#   man (5) nm-settings-keyfile
#
# Params:
#   $nic        the associated network card
#   $interface  the associated network interface
#
# Result:
#   Arrary with formatted lines.
#
#...............................................................................

sub FormatNMKeyfileProfileContent
{
   my ($self, $nic, $interface) = @_;

   # Get the params
   my $onboot      = $self->{_customizationConfig}->Lookup($nic . "|ONBOOT");
   my $bootproto   = $self->{_customizationConfig}->Lookup($nic . "|BOOTPROTO");
   my $dnsfromdhcp = $self->{_customizationConfig}->Lookup("DNS|DNSFROMDHCP");
   my $ipv4Mode    = $self->{_customizationConfig}->GetIpV4Mode($nic);
   my $macaddr     = $self->{_customizationConfig}->GetMACAddress($nic);
   my $primaryNic  = $self->{_customizationConfig}->GetPrimaryNic();

   my @content;

   my (@ipv4NameServers, @ipv6NameServers);
   my $nameServers = $self->{_customizationConfig}->GetNameServers();
   if ($nameServers && @$nameServers) {
      foreach my $nameServer (@$nameServers) {
         # The pattern is just to tell ipv4 name server from ipv6 name server
         if ($nameServer =~ /^\d+\.\d+\.\d+\.\d+$/i) {
            push(@ipv4NameServers, $nameServer);
         } else {
            push(@ipv6NameServers, $nameServer);
         }
      }
   }

   # Format [connection] section
   push(@content, "\n[connection]\n");
   my $id = $NMKEYFILEPROFILEUSERORIGIN . " " . $interface;
   push(@content, "id=$id\n");
   my $uuid = Utils::GetUUID();
   if ($uuid) {
      push(@content, "uuid=$uuid");
   }
   push(@content, "type=ethernet\n");
   push(@content, "interface-name=$interface\n");
   # When autoconnect is omit, its value is true by default
   if ($onboot =~ /yes/i) {
      push(@content, "autoconnect=true\n");
   } elsif ($onboot =~ /no/i) {
      push(@content, "autoconnect=false\n");
   }

   # Format [user] section
   # This is not actually used anywhere, but may be useful in future
   push(@content, "\n[user]\n");
   push(@content,
      "org.freedesktop.NetworkManager.origin=$NMKEYFILEPROFILEUSERORIGIN\n");

   # Format [ethernet] section
   push(@content, "\n[ethernet]\n");
   push(@content, "mac-address=$macaddr\n");

   # Format [ipv4] section
   push(@content, "\n[ipv4]\n");
   my $ipv4Method;
   if ($ipv4Mode eq $ConfigFile::IPV4_MODE_DISABLED) {
      INFO("Marking $interface as IPv4-disabled (method=disabled)");
      $ipv4Method = "disabled";
   } else {
      if ($bootproto =~ /dhcp/i) {
         $ipv4Method = "auto";
         if ($dnsfromdhcp =~ /yes/i) {
            push(@content, "ignore-auto-dns=false\n");
         } elsif ($dnsfromdhcp =~ /no/i) {
            push(@content, "ignore-auto-dns=true\n");
         }
      } else {
         $ipv4Method = "manual";
         my $ipv4Addr = $self->GetIpv4Address($nic);
         if ($ipv4Addr) {
            push(@content, "address1=$ipv4Addr\n");
         }
      }
   }
   push(@content, "method=$ipv4Method\n");
   # [ipv4] Gateway
   my @ipv4Gateways =
      split(/,/, $self->{_customizationConfig}->Lookup($nic . "|GATEWAY"));
   if (@ipv4Gateways) {
      if ((defined $primaryNic) and ($primaryNic ne $nic)) {
         INFO("SKIPPING default gw4 for non-primary NIC '$nic'");
         INFO("NIC '$nic' will not be the default connection for ipv4");
         push(@content, "never-default=true\n");
      } else {
         # Multiple gateways lead to network configuration failure and
         # customer should be advised to use a single gateway
         my $gw4 = @ipv4Gateways[0];
         push(@content, "gateway=$gw4\n");
      }
   }
   # [ipv4] name server
   if (@ipv4NameServers) {
      my $dns = join(";", @ipv4NameServers);
      push(@content, "dns=$dns\n");
   }
   # [ipv4] search domain
   my $dnsSuffixes = $self->{_customizationConfig}->GetDNSSuffixes();
   if ($dnsSuffixes && @$dnsSuffixes) {
      my $dnsSearch = join(";", @$dnsSuffixes);
      push(@content, "dns-search=$dnsSearch\n");
   }

   # Format [ipv6] section
   push(@content, "\n[ipv6]\n");
   my $ipv6Method;
   my @ipv6Addrs = $self->GetIpv6Addresses($nic);
   if (@ipv6Addrs) {
      for (my $index = 0; $index <= $#ipv6Addrs; $index++) {
         my $addrIndex = $index + 1;
         push(@content,
            "address" . $addrIndex . "=" . $ipv6Addrs[$index] . "\n");
      }
      $ipv6Method = "manual";
   } else {
      $ipv6Method = "auto";
      if ($dnsfromdhcp =~ /yes/i) {
         push(@content, "ignore-auto-dns=false\n");
      } elsif ($dnsfromdhcp =~ /no/i) {
         push(@content, "ignore-auto-dns=true\n");
      }
   }
   push(@content, "method=$ipv6Method\n");
   # [ipv6] Gateway
   my @ipv6Gateways = ConfigFile::ConvertToArray(
      $self->{_customizationConfig}->Query("^$nic(\\|IPv6GATEWAY\\|)"));
   if (@ipv6Gateways) {
      if ((defined $primaryNic) and ($primaryNic ne $nic)) {
         INFO("SKIPPING default gw6 for non-primary NIC '$nic'");
         INFO("NIC '$nic' will not be the default connection for ipv6");
         push(@content, "never-default=true\n");
      } else {
         # Multiple gateways lead to network configuration failure and
         # customer should be advised to use a single gateway
         my $gw6 = @ipv6Gateways[0];
         push(@content, "gateway=$gw6\n");
      }
   }
   # [ipv6] name server
   if (@ipv6NameServers) {
      my $dns = join(";", @ipv6NameServers);
      push(@content, "dns=$dns\n");
   }

   return @content;
}

#...............................................................................
#
# GetIpv4Address
#
#   Get the IPv4 address/prefix format string (CIDR notation).
#   Note that our spec only supports one IPv4 address per NIC.
#   This is why we are returning a scalar.
#
# Params:
#   $nic   the associated network card
#
# Result:
#   A formatted IPv4 address/prefix string
#
#...............................................................................

sub GetIpv4Address
{
   my ($self, $nic) = @_;
   my $result;

   my $ipaddr  = $self->{_customizationConfig}->Lookup($nic . "|IPADDR");
   my $netmask = $self->{_customizationConfig}->Lookup($nic . "|NETMASK");

   if ($ipaddr and $netmask) {
      my @parts = split(/\./, $netmask);
      my $prefix = 0;
      for my $part (@parts) {
         $prefix += Utils::CountBits($part);
      }
      $result = $ipaddr . "/" . $prefix;
   }

   return $result;
}

#...............................................................................
#
# GetIpv6Addresses
#
#   Get the IPv6 address/prefix format strings (CIDR notations).
#   Note that our spec supporst multiple IPv6 addresses per NIC.
#   This is why we are returning an array.
#
# Params:
#   $nic   the associated network card.
#
# Result:
#   An array of formatted IPv6 address/prefix strings.
#
#...............................................................................

sub GetIpv6Addresses
{
   my ($self, $nic) = @_;
   my @result;

   my @ipv6Addresses = ConfigFile::ConvertToIndexedArray(
      $self->{_customizationConfig}->Query("^($nic\\|IPv6ADDR\\|)"));
   my @ipv6Netmasks = ConfigFile::ConvertToIndexedArray(
      $self->{_customizationConfig}->Query("^($nic\\|IPv6NETMASK\\|)"));
   my @ipv6Settings = ConfigFile::Transpose(\@ipv6Addresses, \@ipv6Netmasks);

   for my $ipv6Setting (@ipv6Settings) {
      push(@result, $ipv6Setting->[0] . "/" . $ipv6Setting->[1]);
   }

   return @result;
}

#...............................................................................
#
# CustomizeDNS
#
#  DNS Setting is in NetworkManager profile, skip wicked DNS setting
#
#...............................................................................

sub CustomizeDNS
{
}

#...............................................................................
#
# GetSystemUTC
#
#     Get the current hardware clock based on the system setting.
#
# Result:
#     Returns
#         UTC, if hardware clock set to UTC
#         LOCAL, if hardware clock set to LOCAL
#         undef, if fails to get hardware clock
#
# NOTE: /etc/adjtime could be unavailable after setting hardware clock
#...............................................................................

sub GetSystemUTC
{
   my $result = undef;
   my $timedatectlPath = Utils::GetTimedatectlPath();
   if (defined $timedatectlPath) {
      my $timedatectlStatus = Utils::ExecuteCommand("$timedatectlPath status");
      if ($timedatectlStatus =~ /RTC.*in.*local.*TZ:\s+no/i) {
         $result = 'UTC';
      } elsif ($timedatectlStatus =~ /RTC.*in.*local.*TZ:\s+yes/i) {
         $result = 'LOCAL';
      }
   }
   return $result;
}

#..............................................................................
# See Customization.pm#RestartNetwork
#..............................................................................

sub RestartNetwork
{
   my ($self)  = @_;
   my $returnCode;

   # Reload connection profiles from disk
   Utils::ExecuteCommand('nmcli con reload',
                         'Reload connection profiles',
                         \$returnCode);
   if ($returnCode)  {
      die "Failed to reload connection profiles, return code: $returnCode";
   }

   # Move networking off after connection reload since off will move the
   # devices from NetworkManager's management, it's more reasonable to reload
   # the profiles when the devices were managed by NetworkManager.

   # Deactivate all interfaces managed by NetworkManager
   $returnCode =
      Utils::ExecuteCommandWithRetryOnFail('nmcli networking off 2>&1',
                                           'Deactivate all interfaces',
                                           1, # timeout error
                                           3, # interval 3s
                                           4  # retry 4 times
                                           );

   if ($returnCode) {
      die "Failed to deactivate interfaces, return code: $returnCode";
   }

   # Activate all interfaces managed by NetworkManager
   $returnCode =
      Utils::ExecuteCommandWithRetryOnFail('nmcli networking on 2>&1',
                                           'Activate all interfaces',
                                           1, # timeout error
                                           3, # interval 3s
                                           4  # retry 4 times
                                           );

   if ($returnCode) {
      die "Failed to activate interfaces, return code: $returnCode";
   }

   # Restart NetworkManager.service
   Utils::ExecuteCommand('systemctl restart NetworkManager.service 2>&1',
                         'Restart NetworkManager.service',
                         \$returnCode);
   if ($returnCode) {
      die "Failed to restart NetworkManager.service, return code: $returnCode";
   }
}

#..............................................................................
# Bring up the customized Nics for the instant clone flavor of
# guest customization. If the content of the hostname file does not match
# the output value of the hostname command, set hostname to the content of
# the hostname file accordingly.
#..............................................................................

sub InstantCloneNicsUp
{
   my ($self) = @_;

   $self->SUPER::InstantCloneNicsUp();
   $self->SetTransientHostname($SLES16HOSTNAMEFILE);
}

1;
