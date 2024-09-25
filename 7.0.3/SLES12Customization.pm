#!/usr/bin/perl

###############################################################################
#  Copyright (c) 2014-2020, 2024 Broadcom.  All rights reserved.
#  The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
###############################################################################

package SLES12Customization;
use base qw(SLES11Customization);

use strict;
use Debug;

our $OSRELEASEFILE = "/etc/os-release";

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
         if ($2 >= 12) {
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
            if ($2 >= 12) {
               $result = "Suse Linux Enterprise $1 $2";
            }
         }
      }
   }

   return $result;
}

sub CustomizeHostName
{
   my ($self) = @_;

   # Invoking CustomizeHostName in SuseCustomization.pm which writes to
   # /etc/HOSTNAME with host and domain name. Setting hostname for current
   # session.
   my $newHostName   = $self->{_customizationConfig}->GetHostName();

   if (defined $newHostName) {
      Utils::ExecuteCommand("hostname $newHostName");
   }
   $self->SUPER::CustomizeHostName();
}

sub GetInterfaceByMacAddress
{
   my ($self, $macAddress, $ipAddrResult) = @_;

   return $self->GetInterfaceByMacAddressIPAddrShow($macAddress, $ipAddrResult);

}

#...............................................................................
# See Customization.pm#RestartNetwork
#...............................................................................

sub RestartNetwork
{
   my ($self) = @_;
   my $result = 1;
   # Buggy SLES12 wickedd-dhcp4 will get stuck at getting DHCP addresses after
   # an underlying NIC is reset. Therefore, we check for its presence and
   # force a restart of that service to avoid the problem.
   my $output =
      Utils::ExecuteCommandLogStderr('systemctl is-enabled wickedd-dhcp4',
                                     'Check wickedd-dhcp4 enablement',
                                     \$result);
   if ($result == 0 && $output =~ '^enabled') {
      Utils::ExecuteCommand('systemctl restart wickedd-dhcp4 2>&1');
   }

   Utils::ExecuteCommand('systemctl restart network.service 2>&1');
}

sub GetSystemUTC
{
   return  Utils::GetValueFromFile('/etc/adjtime', '(UTC|LOCAL)');
}

sub SetUTC
{
   # /etc/sysconfig/clock file not functional for hardware clock in SLES12,
   # set hardware clock using timedatectl command.
   my ($self, $cfgUtc) = @_;
   my $timedatectlPath = Utils::GetTimedatectlPath();
   if (defined $timedatectlPath) {
      my $commandReturnCode = 1;
      my $utc = ($cfgUtc =~ /yes/i) ? "0" : "1";
      Utils::ExecuteCommandLogStderr("$timedatectlPath set-local-rtc $utc",
                                     "Specify hardware clock",
                                     \$commandReturnCode);
      if ($commandReturnCode != 0) {
         WARN("Specifying hardware clock got error.");
      }
   } else {
      WARN("Specifying hardware clock was skipped.");
   }
}

1;
