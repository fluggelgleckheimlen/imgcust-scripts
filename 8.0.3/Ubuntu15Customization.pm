########################################################################################
#  Copyright (c) 2016-2019, 2021 VMware, Inc.  All rights reserved.
########################################################################################

package Ubuntu15Customization;

# Inherit from Ubuntu13Customization.
# This is used for Ubuntu15.x/16.x customization.
use base qw(Ubuntu13Customization);

use strict;
use Debug;

# Convenience variables
my $UBUNTUINTERFACESFILE = $DebianCustomization::DEBIANINTERFACESFILE;

my $UBUNTURELEASEFILE    = "/etc/lsb-release";

# Max wait time(in seconds) for hostnamectl cmd to be available
my $UBUNTU15_MAX_WAIT_TIME_FOR_HOSTNAMECTL_CMD = 10;

sub DetectDistroFlavour
{
   my ($self) = @_;
   my $result = undef;

   if (-e $Customization::ISSUEFILE) {
      DEBUG("Reading issue file ... ");
      my $issueContent = Utils::ExecuteCommand("cat $Customization::ISSUEFILE");
      DEBUG($issueContent);
      if ($issueContent =~ /Ubuntu\s+(1[5-6]\.(04|10))/i) {
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
         if ($lsbContent =~ /DISTRIB_ID=Ubuntu/i and $lsbContent =~ /DISTRIB_RELEASE=(1[5-6]\.(04|10))/) {
            $result = "Ubuntu $1";
         }
      }
   }

   return $result;
}

sub GetInterfaceByMacAddress
{
   my ($self, $macAddress, $ifcfgResult) = @_;

   if (! defined $ifcfgResult) {
       DEBUG("Get interface name for MAC $macAddress, via [ip addr show]");
       return $self->GetInterfaceByMacAddressIPAddrShow($macAddress);
   }

   # The code below is to keep the unit test passing.
   my $result = undef;

   my $macAddressValid = ($macAddress =~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i);

   if ($macAddressValid &&
      ($ifcfgResult =~ /^\s*(\w+?)(:\w*)?\s+.*?$macAddress/mi)) {
      $result = $1;
   }

   return $result;
}

sub CustomizeHostName
{
   my ($self) = @_;

   my $hostName = $self->{_customizationConfig}->GetHostName();

   # Hostname is optional
   if (! ConfigFile::IsKeepCurrentValue($hostName)) {
      # PR 2162074, 'hostnamectl set-hostname' command may fail due to
      # dbus.service is not running when executes this command.
      # There could have an interval from tools service is active to
      # dbus.service is active depends on the booting sequence of systemd
      # services at startup.
      DEBUG("Check if command [hostnamectl] is available");
      my $commandReturnCode = 1;
      my $timeout = $UBUNTU15_MAX_WAIT_TIME_FOR_HOSTNAMECTL_CMD;
      while ($timeout > 0) {
         Utils::ExecuteCommandLogStderr("hostnamectl status",
                                        "Check if hostnamectl is available",
                                        \$commandReturnCode);
         if ($commandReturnCode != 0) {
            sleep(1);
            $timeout -= 1;
         } else {
            DEBUG("Set host name to $hostName via [hostnamectl set-hostname]");
            Utils::ExecuteCommand("hostnamectl set-hostname $hostName");
            last;
         }
      }
      # PR 2741598, with cloud-init is enabled and running, dbus.service will
      # not start after UBUNTU15_MAX_WAIT_TIME_FOR_HOSTNAMECTL_CMD seconds
      # until cloud-init-local.service done according to their dependency
      # In such case, only use SUPER::CustomizeHostName() to set host name
      # Besides hostnamectl might nuke the hostname file on invalid input
      # looks like a bug with hostnamectl
      # work around it and keep the existing unit tests happy
      $self->SUPER::CustomizeHostName();
   }
};

1;
