#!/usr/bin/perl

########################################################################################
#  Copyright 2008-2019 VMware, Inc.  All rights reserved.
########################################################################################

package UbuntuCustomization;
use base qw(DebianCustomization);

use strict;
use Debug;

# distro detection configuration files
my $UBUNTURELEASEFILE      = "/etc/lsb-release";

# distro detection constants
my $UBUNTU                 = "Ubuntu Linux Distribution";

# distro flavour detection constants
my $UBUNTU_GENERIC         = "Ubuntu";

sub DetectDistro
{
   my ($self) = @_;
   my $result = undef;

   if (-e $UBUNTURELEASEFILE) {
      my $lsbContent = Utils::ExecuteCommand("cat $UBUNTURELEASEFILE");

      if ($lsbContent =~ /Ubuntu/i) {
         $result = $UBUNTU;
      }
   }

   return $result;
}

sub DetectDistroFlavour
{
   my ($self) = @_;

   if (!-e $Customization::ISSUEFILE) {
      WARN("Issue file not available. Ignoring it.");
   }

   DEBUG("Reading issue file ... ");
   DEBUG(Utils::ExecuteCommand("cat $Customization::ISSUEFILE"));

   return $UBUNTU_GENERIC;
}

# The default runlevel is N2 on most versions of ubuntu with system V
sub EnablePostRebootAgentManually
{
   my $post_customization_agent = $Customization::POST_CUSTOMIZATION_AGENT;
   INFO("Enabling post-reboot customization agent manually");
   if (!(-e "/etc/rc2.d" && -e "/etc/rc3.d" && -e "/etc/rc4.d" &&
         -e "/etc/rc5.d")) {
      return;
   }
   INFO("Adding it in runlevel 2, 3, 5 and with priority 99");
   my $cmd2 = "ln -sf $post_customization_agent /etc/rc2.d/S99post-customize-guest";
   my $cmd3 = "ln -sf $post_customization_agent /etc/rc3.d/S99post-customize-guest";
   my $cmd5 = "ln -sf $post_customization_agent /etc/rc5.d/S99post-customize-guest";
   Utils::ExecuteCommand($cmd2);
   Utils::ExecuteCommand($cmd3);
   Utils::ExecuteCommand($cmd5);
   $Customization::runPostCustomizationBeforeReboot = 0;
}


1;
