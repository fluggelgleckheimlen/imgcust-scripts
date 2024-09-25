#!/usr/bin/perl

################################################################################
# Copyright (c) 2008-2024 Broadcom.  All rights reserved.
# The term "Broadcom" refers to Broadcom Inc. and/or its subsidiaries.
################################################################################

#...............................................................................
#
# Customize.pl
#
#  The main script which starts the customization process.
#
#...............................................................................

use strict;

use Debug;
use StdDefinitions qw();
use ConfigFile qw();
use CustomizationInstance qw();
use Utils qw();

my $distroCustomization = undef;
my $customizationResult = $StdDefinitions::CUST_GENERIC_ERROR;

# Get the command line argument count
my $argc = @ARGV;

if ($argc < 1) {
   print "Usage: perl Customize.pl <configfile> \n";
   exit ( -1 );
}

eval
{
   my $ok = Utils::LockCustomization();
   if (not $ok) {
      $customizationResult = $StdDefinitions::CUST_LOCK_ACQUIRE_ERROR;
      die "Cannot lock, another customization instance might be running.";
   }

   # Parse the config file
   my $customizationConfig = new ConfigFile();
   $customizationConfig->LoadConfigFile($ARGV[0]);
   my $directoryName = Utils::DirName($ARGV[0]);
   $customizationConfig->LogBuildInfo($directoryName);

   $distroCustomization =
      CustomizationInstance::LoadCustomizationInstance($customizationConfig);

   # Do Customization
   if ($customizationConfig->GetPostGcStatus()) {
      # must be before everything, since resets Alert in VCD
      Utils::PostGcStatus('Started');
   }
   if (defined $distroCustomization) {
      INFO("Customization started");
      $distroCustomization->Customize($customizationConfig, $directoryName);
      $customizationResult = $distroCustomization->GetCustomizationResult();
   } else {
      if ($customizationConfig->GetPostGcStatus()) {
         # post here or it will be missed due to 'defined $distroCustomization' check below
         Utils::PostGcStatus('Unknown distribution.');
      }
      die "Customization Failure !! Unknown distribution.";
   }
}; if (not $@) {
   if (defined $distroCustomization) {
      if ($distroCustomization->{_customizationConfig}->GetPostGcStatus()) {
         Utils::PostGcStatus('Successful');
      }
   }
   INFO("Customization completed.");
} else {
   ERROR("Fatal error occurred during customization !! Customization halted.");
   ERROR("Error : $@");

   if (defined $distroCustomization) {
      if ($distroCustomization->{_customizationConfig}->GetPostGcStatus()) {
         Utils::PostGcStatus($@);
      }

      if ($customizationResult == $StdDefinitions::CUST_GENERIC_ERROR) {
         $customizationResult = $distroCustomization->GetCustomizationResult();
      }
   }

   INFO("Return code is $customizationResult.");
}

exit $customizationResult;

END {
   Utils::UnlockCustomization();
}
