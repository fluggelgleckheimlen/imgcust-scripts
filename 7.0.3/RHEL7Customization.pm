#!/usr/bin/perl

###############################################################################
#  Copyright (c) 2014-2017, 2020-2023 VMware, Inc.  All rights reserved.
###############################################################################

package RHEL7Customization;
use base qw(RHEL6Customization);

use strict;
use Debug;

use constant HOSTNAME_FILE => "/etc/hostname";
use constant OS_RELEASE_FILE => "/etc/os-release";

our $CENTOS = "CentOS";
our $ORA = "Oracle Linux";
our $ROCKY = "Rocky Linux";
our $ALMA = "Alma Linux";
our $KYLINAS = "Kylin Linux Advanced Server";
our $isRelease86 = 0;

sub DetectDistro
{
   my ($self) = @_;

   return $self->DetectDistroFlavour();
}

sub DetectDistroFlavour()
{
   my ($self) = @_;
   my $result = undef;

   $result = $self->SUPER::DetectDistroFlavour();
   if (! defined $result) {
      # Using PRETTY_NAME's value in the /etc/os-release file to detect Kylin
      # Linux, because the /etc/issue file can only be accessed by the
      # authorized users, and there is no /etc/redhat-release file.
      # # whoami
      # root
      # # cat /etc/issue
      # Authorized users only. All activities may be monitored and reported.
      if (-e OS_RELEASE_FILE) {
         DEBUG("Reading ". OS_RELEASE_FILE . " file ...");
         my $prettyNameValue =
            Utils::GetValueFromFile(OS_RELEASE_FILE, 'PRETTY_NAME[\s\t]*=(.*)');
         $result = $self->FindOsId($prettyNameValue);
      }
   }

   return $result;
}

sub FindOsId
{
   my ($self, $content) = @_;
   my $result = undef;

   if ($content =~ /Red.*Hat.*Enterprise.*Linux.*\s+(\d{1,2})/i) {
      if ($1 == 7 || $1 == 8) {
         $result = "Red Hat Enterprise Linux $1";
         # Detect if the current OS is RHEL8.6 or later
         if ($1 == 8) {
            if ($content =~ /Red.*Hat.*Enterprise.*Linux.*\s+8\.(\d{1,2})/i) {
               if ($1 >= 6) {
                  $isRelease86 = 1;
               }
            }
         }
      }
   } elsif ($content =~ /CentOS.*?release\s+(\d{1,2})/i) {
      if ($1 == 7 || $1 == 8) {
         $result = $CENTOS . " $1";
      }
   } elsif ($content =~ /Oracle.*?release\s+(\d{1,2})/i) {
      if ($1 == 7 || $1 == 8) {
         $result = $ORA . " $1";
      }
   } elsif ($content =~ /Rocky.*?release\s+(\d{1,2})/i) {
      #The first release version of Rocky Linux is 8.3
      if ($1 == 8) {
         $result = $ROCKY . " $1";
         # Detect if the current OS is Rocky8.6 or later
         if ($content =~ /Rocky.*?release\s+8\.(\d{1,2})/i) {
            if ($1 >= 6) {
               $isRelease86 = 1;
            }
         }
      }
   } elsif ($content =~ /Alma.*?release\s+(\d{1,2})/i) {
      #The first release version of Alma Linux is 8.3
      if ($1 >= 8) {
         $result = $ALMA . " $1";
         # Detect if the current OS is Alma8.6 or later
         if ($content =~ /Alma.*?release\s+8\.(\d{1,2})/i) {
            if ($1 >= 6) {
               $isRelease86 = 1;
            }
         }
      }
   } elsif ($content =~ /Kylin.*Linux.*Advanced.*Server\s+V(\d{1,2})/i) {
      # Pre-enable future Kylin Linux Advanced Server V11 and later releases
      if ($1 >= 10) {
         $result = $KYLINAS . " V$1";
      }
   }
   return $result;
}

sub InitOldHostname
{
   my ($self) = @_;

   $self->{_oldHostName} = $self->OldHostnameCmd();
   if (!$self->{_oldHostName}) {
      ERROR("OldHostnameCmd() returned empty name");
   }
   INFO("OLD HOST NAME = $self->{_oldHostName}");
}

sub CustomizeNetwork
{
   my ($self) = @_;

   $self->SUPER::CustomizeNetwork();
   $self->CustomizeHostName();
}

sub CustomizeHostName
{
   my ($self) = @_;

   # if /etc/hostname is present in RHEL7, we want to override hostname in this file.
   if (-e HOSTNAME_FILE) {
      my $newHostname = $self->{_customizationConfig}->GetHostName();
      if (ConfigFile::IsKeepCurrentValue($newHostname)) {
         $newHostname = $self->OldHostName();
      }
      # Ensure new hostname is valid before writing to hostname file. PR #2015226.
      if ($newHostname) {
         Utils::WriteBufferToFile(HOSTNAME_FILE, ["$newHostname\n"]);
         Utils::SetPermission(HOSTNAME_FILE, $Utils::RWRR);
      } else {
         ERROR("Invalid hostname '$newHostname' for " . HOSTNAME_FILE);
      }
   }
}

#...............................................................................
# See Customization.pm#RestartNetwork
#...............................................................................

sub RestartNetwork
{
   my ($self)  = @_;

   if (!$isRelease86) {
      $self->RestartNetworkService();
   } else {
      $self->RestartNetworkManager();
   }
}


#...............................................................................
# Restart network service and run ifdown&ifup for each NIC if restart network
# service fails.
#...............................................................................

sub RestartNetworkService
{
   my ($self)  = @_;
   my $returnCode;

   Utils::ExecuteCommand('systemctl restart network.service 2>&1',
                         'Restart Network Service',
                         \$returnCode);

   if ($returnCode) {
      INFO("Failed to restart network.service, return code: $returnCode");
      my @macs = $self->GetMACAddresses();
      foreach my $mac (@macs) {
         my $if = $self->GetInterfaceByMacAddress($mac);
         if ($if) {
            Utils::ExecuteCommand("ifdown $if 2>&1 && ifup $if 2>&1",
                                  'Call ifdown and ifup',
                                  \$returnCode);
            if ($returnCode) {
               die "Failed to ifdown and ifup $if, return code: $returnCode";
            }
         }
      }
   }
}


#...............................................................................
# PR 2971038
# Network scripts are deprecated since RHEL 8.6, restart NetworkManager and
# call nmcli commands to activate the network-scripts
#...............................................................................

sub RestartNetworkManager
{
   my ($self)  = @_;
   my $returnCode;

   Utils::ExecuteCommand('systemctl restart NetworkManager.service 2>&1',
                         'Restart NetworkManager Service',
                         \$returnCode);
   if ($returnCode) {
      die "Failed to restart NetworkManager Service, return code: $returnCode";
   }

   # Note that when NetworkManager gets restarted, it stores the previous state
   # in /run/NetworkManager; in particular it saves the UUID of the connection
   # that was previously active so that it can be activated again after the
   # restart. Therefore, call nmcli commands to activate the network-scripts
   # profiles.
   my @macs = $self->GetMACAddresses();
   foreach my $mac (@macs) {
      my $if = $self->GetInterfaceByMacAddress($mac);
      if ($if) {
         Utils::ExecuteCommand(
            "nmcli con load /etc/sysconfig/network-scripts/ifcfg-$if 2>&1 &&" .
            " nmcli con up /etc/sysconfig/network-scripts/ifcfg-$if 2>&1",
            'Call nmcli to activate ifcfg-$if',
            \$returnCode);
         if ($returnCode) {
            die "Failed to activate ifcfg-$if, return code: $returnCode";
         }
      }
   }
}

1;
