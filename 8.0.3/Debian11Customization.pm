#!/usr/bin/perl

###############################################################################
#  Copyright (c) 2021-2024 Broadcom. All Rights Reserved.
#  Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
#  and/or its subsidiaries.
###############################################################################

package Debian11Customization;
use base qw(Debian8Customization);

use strict;
use Debug;

our $OSRELEASEFILE = "/etc/os-release";

# distro flavour detection constants
our $Debian11 = "Debian 11";
our $PARDUS = "Pardus";

sub FindOsId
{
   my ($self, $content) = @_;
   my $result = undef;

   #Pre-enabling 12 and later version to work same way as 11
   if ($content =~ /Debian.*GNU.*Linux.*\s+(\d{1,2})/i) {
      if ($1 >= 11) {
         $result = "Debian $1";
      }
   } elsif ($content =~ /Pardus.*GNU.*Linux.*\s+(\d{1,2})/i) {
   # Start supporting Pardus from version 21.x
      if ($1 >= 21) {
         $result = $PARDUS . " $1";
      }
   }

   return $result;
}

sub FindOsVer
{
   my ($self, $content) = @_;
   my $result = undef;

   #Pre-enabling 12 and later version to work same way as 11
   #There is only version number in /etc/debian_version
   #For ex: 11.0
   if ($content =~ /(\d{1,2})\.\d+/i) {
      if ($1 >= 11) {
         $result = "Debian $1"
      }
   }

   return $result;
}

sub DetectDistroFlavour
{
   my ($self) = @_;

   my $result = $self->SUPER::DetectDistroFlavour();
   if (! defined $result) {
      # Using PRETTY_NAME's value in the /etc/os-release file to detect Debian
      # and Pardus Linux when the /etc/issue file content has no distro flavour
      # info.
      if (-e $OSRELEASEFILE) {
         DEBUG("Reading $OSRELEASEFILE file ...");
         my $value = Utils::GetValueFromFile($OSRELEASEFILE,
            'PRETTY_NAME[\s\t]*=(.*)');
         $result = $self->FindOsId($value);
      }
   }

   return $result;
}

sub GetMACAddresses
{
   my ($self) = @_;

   my $ipAddrResult = Utils::ExecuteCommand('/sbin/ip addr show 2>&1');
   my @macs = ();

   while ($ipAddrResult =~ /link\/ether\s(\w{2}:\w{2}:\w{2}:\w{2}:\w{2}:\w{2})/g) {
      my $mac = $1;
      my $interface = $self->GetInterfaceByMacAddress($mac);
      if ($interface =~ /^vir/) {
         next; # skip virtual interfaces by KVMs.
      }
      push(@macs, $mac);
   }

   return @macs;
}

# See Customization.pm#RestartNetwork
sub RestartNetwork
{
   my ($self) = @_;

   # If NetworkManager is running, wait before restarting.
   # Restarting NM too quickly after Customize() can put network in a bad state.
   # Mask STDERR "unrecognized service" when NM is not installed.
   my $nmStatus = Utils::ExecuteCommand("service NetworkManager status 2>&1");
   my $nmRunning = ($nmStatus =~ /running/i);
   if ($nmRunning) {
      sleep 5;
      Utils::ExecuteCommand("service NetworkManager restart 2>&1");
   }

   # Flush out the ip address after restart NetworkManager service
   # See PR 2884966 for details
   my @macs = $self->GetMACAddresses();
   foreach my $mac (@macs) {
      my $if = $self->GetInterfaceByMacAddress($mac);
      if ($if) {
         Utils::ExecuteCommand("ip addr flush dev $if 2>&1");
      }
   }

   Utils::ExecuteCommand("/etc/init.d/networking restart 2>&1");
}


1;
