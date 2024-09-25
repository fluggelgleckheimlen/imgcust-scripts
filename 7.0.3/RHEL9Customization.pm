#!/usr/bin/perl

###############################################################################
#  Copyright (c) 2023 VMware, Inc.  All rights reserved.
###############################################################################

package RHEL9Customization;
use base qw(RHEL7Customization);

use strict;
use Debug;

sub FindOsId
{
   my ($self, $content) = @_;
   my $result = undef;

   if ($content =~ /Red.*Hat.*Enterprise.*Linux.*\s+(\d{1,2})/i) {
      if ($1 >= 9) {
         $result = "Red Hat Enterprise Linux $1";
      }
   } elsif ($content =~ /CentOS.*?release\s+(\d{1,2})/i) {
      if ($1 >= 9) {
         $result = $RHEL7Customization::CENTOS . " $1";
      }
   } elsif ($content =~ /Oracle.*?release\s+(\d{1,2})/i) {
      if ($1 >= 9) {
         $result = $RHEL7Customization::ORA . " $1";
      }
   } elsif ($content =~ /Rocky.*?release\s+(\d{1,2})/i) {
      #Pre-enable Rocky Linux 9.x
      if ($1 >= 9) {
         $result = $RHEL7Customization::ROCKY . " $1";
      }
   } elsif ($content =~ /Alma.*?release\s+(\d{1,2})/i) {
      #Pre-enable Alma Linux 9.x
      if ($1 == 9) {
         $result = $RHEL7Customization::ALMA . " $1";
      }
   }
   return $result;
}

sub FormatIFCfgContent
{
   my ($self, $nic ,$interface) = @_;

   my @content;

   # Connection priority for automatic activation. Connections with higher
   # numbers are preferred when selecting profiles for automatic activation.
   # Example: AUTOCONNECT_PRIORITY=20 Allowed values: -999 to 999
   push(@content, "AUTOCONNECT_PRIORITY=999\n");

   # Set up the rest of the fields.
   push(@content, $self->SUPER::FormatIFCfgContent($nic, $interface));

   return @content;
}

sub RestartNetwork
{
   my ($self)  = @_;
   $self->SUPER::RestartNetworkManager();
}

1;
