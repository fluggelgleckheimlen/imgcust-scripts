#!/usr/bin/perl

################################################################################
# Copyright (c) 2024 Broadcom.  All rights reserved.
# The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
################################################################################

#...............................................................................
#
# CustomizationInstance.pm
#
#  This module manages the supported Guest OS and serves as an adaptor.
#
#  README : ADDING CUSTOMIZATION FOR NEW DISTROs
#     1. Derive the Customization class
#     2. Implement the methods called in this script
#     3. Follow the steps marked with [NewDistroSupport]
#
#...............................................................................

package CustomizationInstance;

use strict;
use ConfigFile qw();
use Debug;
use Cwd qw(abs_path);
use File::Spec;
use Utils qw();
use Scalar::Util qw(blessed);

use RedHatCustomization qw();
use SuSECustomization qw();
use DebianCustomization qw();
use Debian8Customization qw();
use Debian11Customization qw();
use UbuntuCustomization qw();
use SunOSCustomization qw();
use SLES11Customization qw();
use SLES12Customization qw();
use RHEL6Customization qw();
use RHEL7Customization qw();
use RHEL9Customization qw();
use RHEL10Customization qw();
use Ubuntu10Customization qw();
use Ubuntu11Customization qw();
use Ubuntu12Customization qw();
use Ubuntu13Customization qw();
use Ubuntu15Customization qw();
use Ubuntu17Customization qw();
use AmazonLinuxCustomization qw();
use UbuntuNetplanCustomization qw();
use Ubuntu1910Customization qw();
use Ubuntu2310Customization qw();
# [NewDistroSupport] STEP1: Use new customization module here

# customization.conf file
my $TOOLS_CUST_CONF = '/etc/vmware-tools/customization.conf';
# This flag is only used in instant clone customization
my $usingGoscMethodIdFromCustConf = 0;
# Save gosc method in instant clone customization for NicsUp
my $GOSC_METHOD_FILE = '.gosc_method_id';

#...............................................................................
#
# GetGoscMethodIdFromToolsCustConf
#
#   Get GOSC|COMPATIBILITY setting from tools customization.conf file
#
# Params:
#   None.
#
# Result:
#   GOSC_METHOD_ID if it's provided, undef otherwise.
#
#..............................................................................

sub GetGoscMethodIdFromToolsCustConf
{
   my $goscMethodId = undef;
   if (-e $TOOLS_CUST_CONF) {
      my $toolsCustomizationConf = new ConfigFile();
      $toolsCustomizationConf->LoadConfigFile($TOOLS_CUST_CONF);
      $goscMethodId = $toolsCustomizationConf->GetCompatibility();
      if (not defined $goscMethodId or length($goscMethodId) == 0) {
         $goscMethodId = undef;
         INFO("No GOSC|COMPATIBILITY setting in $TOOLS_CUST_CONF");
      }
   } else {
      INFO("$TOOLS_CUST_CONF doesn't exist.");
   }

   return $goscMethodId;
}

#...............................................................................
#
# GetGoscMethodId
#
#   Parse customization method id with key "COMPATIBILITY".
#   Firstly get customization method id from tools customization.conf file.
#   If it's not provided, try to get it from customization config file.
#
# Params:
#   $customizationConfig Customization config object
#
# Result:
#   Return $goscMethodId if it's available, and undef otherwise.
#...............................................................................

sub GetGoscMethodId
{
   my ($customizationConfig) = @_;
   my $goscMethodId = undef;
   $goscMethodId = GetGoscMethodIdFromToolsCustConf();
   if (defined $goscMethodId) {
      INFO("Using $goscMethodId from $TOOLS_CUST_CONF");
   } else {
      $goscMethodId = $customizationConfig->GetCompatibility();
      if (defined $goscMethodId) {
         INFO("Using $goscMethodId from cust.cfg");
      }
   }
   return $goscMethodId;
}

#...............................................................................
#
# SaveGoscMethodIdForIcNicsUp
#
#   In instant clone customization workflow, save $goscMethodId into
#   $GOSC_METHOD_FILE for NicsUp. When it's provided by cust.cfg, NicsUp
#   can't get it because cust.cfg is not available in NicsUp workflow.
#   It will be used as legacy config item in NicsUp.
#
# Params:
#   $goscMethodId          GOSC_METHOD_ID from cust.cfg
#
# Result:
#   None
#...............................................................................

sub SaveGoscMethodIdForIcNicsUp
{
   my ($goscMethodId) = @_;

   my $dir = Utils::DirName(abs_path(__FILE__));
   my $goscMethodPath = File::Spec->join($dir, $GOSC_METHOD_FILE);
   Utils::ExecuteCommand("rm -rf $goscMethodPath");
   Utils::WriteLineToFile($goscMethodPath, $goscMethodId);
   Utils::SetPermission($goscMethodPath, $Utils::RW00);
   INFO("Saved $goscMethodPath for NicsUp");
}

#...............................................................................
#
# LoadGoscMethodIdForIcNicsUp
#
#   In instant clone NicsUp workflow, load GOSC_METHOD_ID from GOSC_METHOD_FILE.
#   The GOSC_METHOD_FILE is saved by last instant clone customization.
#
# Params:
#   None
#
# Result:
#   $goscMethodId
#...............................................................................

sub LoadGoscMethodIdForIcNicsUp
{
   my $goscMethodId = undef;
   my $dir = Utils::DirName(abs_path(__FILE__));
   my $goscMethodPath = File::Spec->join($dir, $GOSC_METHOD_FILE);
   if (-e $goscMethodPath) {
      my @lines = Utils::ReadFileIntoBuffer($goscMethodPath);
      $goscMethodId = $lines[0];
      INFO("Using $goscMethodId from $goscMethodPath");
      INFO("Deleting Instant Clone customization file $goscMethodPath");
      Utils::ExecuteCommand("rm -rf $goscMethodPath");
   } else {
      INFO("$goscMethodPath doesn't exist");
   }
   return $goscMethodId;
}

#...............................................................................
#
# GetGoscMethodIdForIc
#
#   Parse customization method id with key "COMPATIBILITY".
#   Firstly get customization method id from tools customization.conf file.
#   If it's not provided, try to get it from customization config file.
#   And cust.cfg is not provided in instant clone NicsUp, so try to get gosc
#   method id from instant clone customization legacy.
#
# Params:
#   $isInstantCloneNicsUp Is it called by instant clone NicsUp
#   $customizationConfig Customization config object
#
# Result:
#   Return $goscMethodId if it's available, and undef otherwise.
#...............................................................................

sub GetGoscMethodIdForIc
{
   my ($isInstantCloneNicsUp, $customizationConfig) = @_;
   my $goscMethodId = undef;

   $goscMethodId = GetGoscMethodIdFromToolsCustConf();
   if (defined $goscMethodId) {
      INFO("Using $goscMethodId from $TOOLS_CUST_CONF");
   } else {
      if ($isInstantCloneNicsUp) {
         # This is Instant Clone NicsUp workflow. There is no cust.cfg
         # in NicsUp, try to get gosc method id from Ic customization
         # legacy.
         $goscMethodId = LoadGoscMethodIdForIcNicsUp();
      } else {
         # This is Instant Clone customization workflow
         $goscMethodId = $customizationConfig->GetCompatibility();
         if (defined $goscMethodId) {
            $usingGoscMethodIdFromCustConf = 1;
            INFO("Using $goscMethodId from cust.cfg");
         }
      }
   }

   return $goscMethodId;
}

#...............................................................................
#
# MatchGuestOS
#
#   Find a matched customization instance by detecting distro and distro flavors
#
# Params:
#   @customizations All supported customization instances
#
# Result:
#   Return matched customization instance or undef if no matched one available
#...............................................................................

sub MatchGuestOS
{
   my @customizations = @_;

   my $instance = undef;

   # Find customization that supports the distro
   INFO("Matching guest OS by distribution flavour...");
   foreach (@customizations) {
      my $distro = $_->DetectDistro();

      if (defined $distro) {
         INFO("Detected distribution: $distro");
         $instance = $_;

         # Flavour is not mandatory for customizing a distro
         my $flavour = $_->DetectDistroFlavour();

         if (defined $flavour) {
            INFO("Detected distribution flavour: $flavour");
         } else {
            WARN("Unknown $distro distribution flavour.");
         }

         last;
      }
   }

   if (defined $instance) {
      my $instanceName = blessed($instance);
      INFO("Customization instance $instanceName loaded.");
   }

   return $instance;
}

sub LoadCustomizationInstanceFromMethodId
{
   my ($goscMethodId) = @_;

   my $distroCustomization = undef;
   if ($goscMethodId =~ /GOSC_METHOD_(\d{1,2})/i) {
      my $id = $1;
      if ($id == 1) {       # GOSC_METHOD_1
         $distroCustomization = new RHEL7Customization();
      } elsif ($id == 2) {  # GOSC_METHOD_2
         $distroCustomization = new SLES12Customization();
      } elsif ($id == 3) {  # GOSC_METHOD_3
         $distroCustomization = new Debian8Customization();
      } elsif ($id == 4) {  # GOSC_METHOD_4
         $distroCustomization = new Ubuntu17Customization();
      } elsif ($id == 5) {  # GOSC_METHOD_5
         $distroCustomization = new Ubuntu1910Customization();
      } elsif ($id == 6) {  # GOSC_METHOD_6
         $distroCustomization = new Debian11Customization();
      } elsif ($id == 7) {  # GOSC_METHOD_7
         # Set isRelease86 for METHOD 7 to call RestartNetworkManager
         # for RHEL8.6 or above.
         $distroCustomization = new RHEL7Customization();
         $RHEL7Customization::isRelease86 = 1;
      } elsif ($id == 8) {  # GOSC_METHOD_8
         $distroCustomization = new RHEL9Customization();
      } elsif ($id == 9) {  # GOSC_METHOD_9
         $distroCustomization = new Ubuntu2310Customization();
      } elsif ($id == 10) { # GOSC_METHOD_10
         $distroCustomization = new RHEL10Customization();
      # [NewDistroSupport] STEP2:
      # 1. Add new customization method here
      # 2. Update MAX_GOSC_METHOD_ID in //bora/vpx/vpxd/gosc/custSpecUtil.cpp
      # 3. Update https://kb.vmware.com/s/article/95903
      } else {
         WARN("The compatibility value $goscMethodId is not supported, " .
              "see details in https://kb.vmware.com/s/article/95903\n" .
              "Ignore and continue to detect the distro flavor.");
      }
      if (defined $distroCustomization) {
         my $instanceName = blessed($distroCustomization);
         INFO("Customization instance $instanceName loaded as " .
              "compatibility mode.");
      }
   } else {
      WARN("Invalid compatibility value: $goscMethodId, " .
           "see details in https://kb.vmware.com/s/article/95903\n" .
           "Ignore and continue to detect the distro flavor.");
   }

   return $distroCustomization;
}

#...............................................................................
#
# LoadCustomizationInstance
#
#   Match the guest OS and create the corresponding customization object for
#   the guest in traditional customization workflow.
#
# Params:
#   $customizationConfig          The customization ConfigFile object
#
# Result:
#   Return the proper guest customization object.
#...............................................................................

sub LoadCustomizationInstance
{
   my ($customizationConfig) = @_;

   my $distroCustomization = undef;

   my $goscMethodId = GetGoscMethodId($customizationConfig);
   # If GOSC_METHOD_ID is provided, use it to map the corresponding
   # customization object.
   if (defined $goscMethodId) {
      $distroCustomization =
         LoadCustomizationInstanceFromMethodId($goscMethodId);
   }

   if (not defined $distroCustomization) {
      my @customizations = (
         new SLES12Customization(),
         new SLES11Customization(),
         new AmazonLinuxCustomization(),
         new RHEL10Customization(),
         new RHEL9Customization(),
         new RHEL7Customization(),
         new RHEL6Customization(),
         new RedHatCustomization(),
         new SuSECustomization(),
         new Ubuntu2310Customization(),
         new Ubuntu1910Customization(),
         new UbuntuNetplanCustomization(),
         new Ubuntu17Customization(),
         new Ubuntu15Customization(),
         new Ubuntu13Customization(),
         new Ubuntu12Customization(),
         new Ubuntu11Customization(),
         new Ubuntu10Customization(),
         new UbuntuCustomization(),
         new Debian11Customization(),
         new Debian8Customization(),
         new DebianCustomization(),
         new SunOSCustomization()
         # [NewDistroSupport] STEP3: Use new customization module here
      );
      $distroCustomization = MatchGuestOS(@customizations);
   }

   return $distroCustomization;
}

#...............................................................................
#
# LoadCustomizationInstanceForIc
#
#   Match the guest OS and create the corresponding customization object for
#   the guest in instant clone customization workflow.
#
# Params:
#   $isInstantCloneNicsUp         Is it called by Instant clone NicsUp
#   $customizationConfig          The customization ConfigFile object
#
# Result:
#   Return the proper guest customization object.
#...............................................................................

sub LoadCustomizationInstanceForIc
{
   my ($isInstantCloneNicsUp, $customizationConfig) = @_;

   my $distroCustomization = undef;

   my $goscMethodId = GetGoscMethodIdForIc($isInstantCloneNicsUp,
                                           $customizationConfig);
   # If GOSC_METHOD_ID is provided, use it to map the corresponding
   # customization object.
   if (defined $goscMethodId) {
      $distroCustomization =
         LoadCustomizationInstanceFromMethodId($goscMethodId);
      if (!($isInstantCloneNicsUp) && ($usingGoscMethodIdFromCustConf) &&
          (defined $distroCustomization)) {
         # This is instant clone customization workflow, save the $goscMethodId
         # from cust.cfg for NicsUp because cust.cfg is not available in NicsUp
         SaveGoscMethodIdForIcNicsUp($goscMethodId);
      }
   }

   if (not defined $distroCustomization) {
      my @instantCloneCustomizations = (
         new SLES12Customization(),
         new SLES11Customization(),
         new AmazonLinuxCustomization(),
         new RHEL10Customization(),
         new RHEL9Customization(),
         new RHEL7Customization(),
         new RHEL6Customization(),
         new RedHatCustomization(),
         new Ubuntu2310Customization(),
         new Ubuntu1910Customization(),
         new UbuntuNetplanCustomization(),
         new Ubuntu17Customization(),
         new Ubuntu15Customization(),
         new Ubuntu13Customization(),
         new Ubuntu12Customization(),
         new Ubuntu11Customization(),
         new Ubuntu10Customization(),
         new UbuntuCustomization(),
         new Debian11Customization(),
         new Debian8Customization(),
         new DebianCustomization()
         # [NewDistroSupport] STEP4: Use new customization module here if it's
         # supported in Instant Clone customization
      );
      $distroCustomization = MatchGuestOS(@instantCloneCustomizations);
   }

   return $distroCustomization;
}
#...............................................................................
# Return value for module as required for perl
#...............................................................................

1;
