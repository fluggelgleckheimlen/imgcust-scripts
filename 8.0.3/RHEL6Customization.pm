#!/usr/bin/perl

################################################################################
#  Copyright (c) 2010-2025 Broadcom. All Rights Reserved.
#  Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
#  and/or its subsidiaries.
################################################################################

package RHEL6Customization;
use base qw(RedHatCustomization);

use strict;
use Debug;

# distro flavour detection constants
our $RHEL6 = "Red Hat Enterprise Linux 6";
our $CENTOS6 = "Cent OS 6.X";
our $OLINUX6 = "Oracle Linux 6.X";

my $NETWORKSCRIPTSPATH = "/etc/sysconfig/network-scripts";

sub DetectDistro
{
   my ($self) = @_;

   return $self->DetectDistroFlavour();
}

sub FindOsId
{
   my ($self, $content) = @_;
   my $result = undef;

   if ($content =~ /Red.*Hat.*Enterprise.*Linux.*\s+6/i) {
      $result = $RHEL6;
   } elsif ($content =~ /CentOS.*?release\s+6/i) {
      $result = $CENTOS6;
   } elsif ($content =~ /Oracle.*?release\s+6/i) {
      $result = $OLINUX6;
   }
   return $result;
}

sub CustomizeNetwork
{
   my ($self) = @_;

   $self->RemoveOldIFCfgFiles();

   $self->SUPER::CustomizeNetwork();
}

sub RemoveOldIFCfgFiles
{
   my ($self) = @_;

   if (-d $NETWORKSCRIPTSPATH) {
      # If there is an ifcfg-ethX file with NM_CONTROLLED=no, NM will ignore
      # the rest of the ifcfg-ethX files and instead create "Auth ethX"
      # profiles.
      INFO("Removing old interface configuration files.");
      my $networkConfigFiles = $NETWORKSCRIPTSPATH . "/ifcfg-*";
      Utils::DeleteFiles(glob($networkConfigFiles));
   }
}

sub FormatIFCfgContent
{
   my ($self, $nic ,$interface) = @_;

   # Some server and most desktop default installations of RHEL6 have NM
   # enabled by default. These additional entries are needed to
   # cooperate with NM.
   my $macaddr = $self->{_customizationConfig}->GetMACAddress($nic);
   my @content;

   # Set fields to be visible in the NetworkManager gui applet.
   push(@content, "NAME=$interface\n");

   # Set up the default gateway.
   my @ipv4Gateways = $self->{_customizationConfig}->GetGateways($nic);

   # ifcfg-ethX file supports 1 default gateway.
   if (@ipv4Gateways) {
      if (scalar(@ipv4Gateways) > 1) {
         WARN("More than 1 gateway detected. Only the first one will be used.");
      }
      push(@content, "GATEWAY=$ipv4Gateways[0]\n");
   }

   # Set up name servers in ifcfg.
   # NetworkManager will overwrite /etc/resolv.conf on startup.
   my $dnsNameservers = $self->{_customizationConfig}->GetNameServers();
   if ($dnsNameservers) {
      my $i = 1;

      foreach (@$dnsNameservers) {
         push(@content, "DNS$i=$_\n");
         $i++;
      }
   }

   # Set up dns suffix search list
   my $dnsSuffixes = $self->{_customizationConfig}->GetDNSSuffixes();
   if ($dnsSuffixes && @$dnsSuffixes) {
      push(@content, "DOMAIN=\"" . join(' ', @$dnsSuffixes) . "\"\n");
   }

   # Set up the rest of the fields.
   push(@content, $self->SUPER::FormatIFCfgContent($nic, $interface));

   return @content;
}

sub FormatIPv6IFCfgContent
{
   my ($self, $nic) = @_;
   my @content;

   # Set up the default gateway.
   my @ipv6Gateways =
      ConfigFile::ConvertToArray(
         $self->{_customizationConfig}->Query("^$nic(\\|IPv6GATEWAY\\|)"));

   # ifcfg-ethX file supports 1 default gateway.
   if (@ipv6Gateways) {
      if (scalar(@ipv6Gateways) > 1) {
         WARN("More than 1 IPv6 gateway detected. Only the first one will be used.");
      }
      push(@content, "IPV6_DEFAULTGW=$ipv6Gateways[0]\n");
   }

   # Set up all other IPv6 fields.
   push (@content, $self->SUPER::FormatIPv6IFCfgContent($nic));

   return @content;
}

sub AddRoute
{
   my ($self, $interface) = @_;

   # Some server and most desktop default installations of RHEL6 have NM
   # enabled by default.
   # NetworkManager's ifcfg-rh plugin does not like our "route-ethX" entries,
   # so we will cleanup default gateway from "route-ethX" file
   # and put default gateway into "ifcfg-ethX" file.
   $self->SUPER::CleanupDefaultRoute($interface);
}

sub GetSystemUTC
{
   return  Utils::GetValueFromFile('/etc/adjtime', '(UTC|LOCAL)');
}

sub SetUTC
{
   my ($self, $cfgUtc) = @_;

   # /etc/sysconfig/clock file UTC parameter does not work in RHEL 6.x,
   # set hardware clock using hwclock command.
   my $hwPath = Utils::GetHwclockPath();
   if (defined $hwPath) {
      my $utc = ($cfgUtc =~ /yes/i) ? "utc" : "localtime";
      Utils::ExecuteCommand("$hwPath --systohc --$utc");
   } else {
      WARN("Specifying hardware clock was skipped.");
   }
}

#...............................................................................
# See Customization.pm#RestartNetwork
#...............................................................................

sub RestartNetwork
{
   my ($self)  = @_;
   my $returnCode;

   Utils::ExecuteCommand('service network restart 2>&1',
                         'Restart Network Service',
                         \$returnCode);

   if ($returnCode) {
      die "Failed to restart network, service code: $returnCode";
   }
}

1;
