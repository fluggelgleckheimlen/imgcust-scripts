################################################################################
#  Copyright 2019-2020 VMware, Inc.  All rights reserved.
################################################################################

package Ubuntu1910Customization;

# Inherit from UbuntuNetplanCustomization.
use base qw(UbuntuNetplanCustomization);

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

      # Assume Ubuntu 19.10 and later versions can also use the same code in
      # this module.
      # Otherwise, extend this module and add additional code.
      if ($issueContent =~ /Ubuntu\s+(\d+\.\d+)/i) {
         if ($1 >= 19.10) {
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
            if ($1 >= 19.10) {
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

1;
