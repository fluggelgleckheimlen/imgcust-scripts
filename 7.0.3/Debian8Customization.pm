#!/usr/bin/perl

###############################################################################
#  Copyright (c) 2017, 2020-2021, 2024 Broadcom.  All rights reserved.
#  The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
###############################################################################

package Debian8Customization;
use base qw(DebianCustomization);

use strict;
use Debug;

# distro flavour detection constants
our $Debian8 = "Debian 8";
our $Debian9 = "Debian 9";
our $Debian10 = "Debian 10";

# default location for post-reboot script
our $POST_CUSTOMIZATION_AGENT_DEBIAN = "/etc/init.d/post-customize-guest";

sub FindOsId
{
   my ($self, $content) = @_;
   my $result = undef;

   if ($content =~ /Debian.*GNU.*Linux.*\s+(\d{1,2})/i) {
      if ($1 >= 8 && $1 <= 10) {
         $result = "Debian $1";
      }
   }

   return $result;
}

sub FindOsVer
{
   my ($self, $content) = @_;
   my $result = undef;

   #There is only version number in /etc/debian_version
   #For ex:
   #   8.0
   #   9.1
   #   10.0
   #   10.4
   if ($content =~ /(\d{1,2})\.\d+/i) {
      if ($1 >= 8 && $1 <= 10) {
         $result = "Debian $1";
      }
   }

   return $result;
}

sub GetInterfaceByMacAddress
{
   my ($self, $macAddress, $ipAddrResult) = @_;

   return $self->GetInterfaceByMacAddressIPAddrShow($macAddress, $ipAddrResult);

}

sub DHClientConfPath
{
   # Starting with Debian 7, the DHCP client package changed from
   # dhcp3-client to isc-dhcp-client. This new package installs and uses conf
   # file from /etc/dhcp/. Prior to this, it was from /etc/dhcp3/
   return "/etc/dhcp/dhclient.conf";
}

sub GetSystemUTC
{
   return Utils::GetValueFromFile('/etc/adjtime', '(UTC|LOCAL)');
}

sub SetUTC
{
   my ($self, $cfgUtc) = @_;

   # /etc/default/rcS file UTC parameter is removed,
   # set hardware clock using hwclock command.
   my $hwPath = Utils::GetHwclockPath();
   if (defined $hwPath) {
      my $utc = ($cfgUtc =~ /yes/i) ? "utc" : "localtime";
      Utils::ExecuteCommand("$hwPath --systohc --$utc");
   } else {
      WARN("Specifying hardware clock was skipped.");
   }
}

# See Customization.pm#RestartNetwork
sub RestartNetwork
{
   my ($self) = @_;

   # If NetworkManager is running, wait before restarting.
   # Restarting NM too quickly after Customize() can put network in a bad state.
   # Mask STDERR "unrecognized service" when NM is not installed.
   my $nmStatus = Utils::ExecuteCommand("service network-manager status 2>&1");
   my $nmRunning = ($nmStatus =~ /running/i);
   if ($nmRunning) {
      sleep 5;
      Utils::ExecuteCommand("service network-manager restart 2>&1");
   }
   Utils::ExecuteCommand("/etc/init.d/networking restart 2>&1");
}


1;
