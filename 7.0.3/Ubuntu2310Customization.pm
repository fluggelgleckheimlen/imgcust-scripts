################################################################################
#  Copyright (c) 2024 Broadcom.  All rights reserved.
#  The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
################################################################################

package Ubuntu2310Customization;

# Inherit from Ubuntu1910Customization.
use base qw(Ubuntu1910Customization);

use strict;
use Debug;

my $UBUNTURELEASEFILE = "/etc/lsb-release";

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

      # Assume Ubuntu 23.10 and later versions can also use the same code in
      # this module.
      # Otherwise, extend this module and add additional code.
      if ($issueContent =~ /Ubuntu\s+(\d+\.\d+)/i) {
         if ($1 >= 23.10) {
            $result = "Ubuntu $1";
         }
      }
   } else {
      WARN("Issue file not available. Ignoring it.");
   }

   if(! defined $result) {
      if (-e $UBUNTURELEASEFILE) {
         my $lsbContent = Utils::ExecuteCommand("cat $UBUNTURELEASEFILE");
         if ($lsbContent =~ /DISTRIB_ID=Ubuntu/i and
             $lsbContent =~ /DISTRIB_RELEASE=(\d+\.\d+)/) {
            if ($1 >= 23.10) {
               $result = "Ubuntu $1";
            }
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

   return $self->DetectDistroFlavour();
}

#...............................................................................
#
# SetUTC
#
#     Sets whether the hardware clock is in UTC or local time.
#
# Params:
#     $cfgUtc - yes or no
#
# Result:
#     None
#
#...............................................................................

sub SetUTC
{
   my ($self, $cfgUtc) = @_;

   # PR 3293381
   # hwclock command is not available in Ubuntu 23.10,
   # set hardware clock using timedatectl command.
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

1;
