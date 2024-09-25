#!/usr/bin/perl

###############################################################################
# Copyright (c) 2024 Broadcom. All Rights Reserved.
# Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
# and/or its subsidiaries.
###############################################################################

package RHEL10Customization;
use base qw(RHEL9Customization);

use strict;
use Debug;

sub FindOsId
{
   my ($self, $content) = @_;
   my $result = undef;

   if ($content =~ /Red.*Hat.*Enterprise.*Linux.*\s+(\d{1,2})/i) {
      if ($1 >= 10) {
         $result = "Red Hat Enterprise Linux $1";
      }
   } elsif ($content =~ /CentOS.*?release\s+(\d{1,2})/i) {
      if ($1 >= 10) {
         $result = $RHEL7Customization::CENTOS . " $1";
      }
   } elsif ($content =~ /Oracle.*?release\s+(\d{1,2})/i) {
      if ($1 >= 10) {
         $result = $RHEL7Customization::ORA . " $1";
      }
   } elsif ($content =~ /Rocky.*?release\s+(\d{1,2})/i) {
      # Match Rocky Linux 10.x and later version
      if ($1 >= 10) {
         $result = $RHEL7Customization::ROCKY . " $1";
      }
   } elsif ($content =~ /Alma.*?release\s+(\d{1,2})/i) {
      # Match Alma Linux 10.x and later version
      if ($1 >= 10) {
         $result = $RHEL7Customization::ALMA . " $1";
      }
   } elsif ($content =~ /MIRACLE.*?release\s+(\d{1,2})/i) {
      # Match Miracle Linux 10.x and later version
      if ($1 >= 10) {
         $result = $RHEL7Customization::MIRACLE . " $1";
      }
   }
   return $result;
}

sub CustomizeSpecificNIC
{
   my ($self, $nic) = @_;

   # Write network configuration for the specified nic in keyfile format only,
   # ifcfg-rh profile is not supported by NetworkManager since RHEL 10.0,
   # so we do not touch network-scripts any more.
   $self->SUPER::WriteNMKeyfileProfile($nic);
}

1;
