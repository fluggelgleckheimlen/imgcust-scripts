#!/usr/bin/perl

###############################################################################
#  Copyright 2018, 2020 VMware, Inc.  All rights reserved.
###############################################################################

package AmazonLinuxCustomization;
use base qw(RHEL7Customization);

use strict;
use Debug;

our $AMAZONLINUX_GENERIC = "Amazon Linux";

our $AMAZONLINUXRELEASEFILE = "/etc/os-release";

sub DetectDistro
{
   my ($self) = @_;

   return $self->DetectDistroFlavour();
}

sub DetectDistroFlavour
{
   my ($self) = @_;
   my $result = undef;

   # In Amazon Linux VM, /etc/issue file exists but contains the
   # following information.
   # \S
   # Kernel \r on an \m
   #
   # So, no need to check for /etc/issue. We can directly check
   # for /etc/os-release file.
   #
   # An example of the contents of /etc/os-release:
   # NAME="Amazon Linux"
   # VERSION="2.0 (2017.12)"
   # ID="amzn"
   # ID_LIKE="centos rhel fedora"
   # VERSION_ID="2.0"
   # PRETTY_NAME="Amazon Linux 2 (2017.12) LTS Release Candidate"
   # ANSI_COLOR="0;33"
   # CPE_NAME="cpe:2.3:o:amazon:amazon_linux:2.0"
   # HOME_URL="https://amazonlinux.com/"
   #

   if (-e $AMAZONLINUXRELEASEFILE) {
      DEBUG("Reading $AMAZONLINUXRELEASEFILE file ... ");
      my $id = Utils::GetValueFromFile(
         $AMAZONLINUXRELEASEFILE,
         'ID[\s\t]*=(.*)');
      DEBUG("ID: $id");

      my $version = Utils::GetValueFromFile(
         $AMAZONLINUXRELEASEFILE,
         'VERSION_ID[\s\t]*=(.*)');
      DEBUG("Version: $version");

      $result = $self->FindOsId($id, $version);
   } else {
      WARN("$AMAZONLINUXRELEASEFILE not available. Ignoring it");
   }

   if (defined $result) {
      DEBUG("Detected flavor: '$result'");
   } else {
      WARN("Amazon Linux flavor not detected");
   }

   return $result;
}

sub FindOsId
{
   my ($self, $id, $version) = @_;
   my $result = undef;
   # ID="amzn"
   if ($id =~ /amzn/) {
     # Possible version ids for Amazon Linux 2:
     #     VERSION_ID="2"
     #     VERSION_ID="2.0"
     #     VERSION_ID="2.1.3"
     # Possible version ids for Amazon Linux generic:
     #     VERSION_ID="2015.03"
     #     VERSION_ID="2016.09"
     $result = $AMAZONLINUX_GENERIC;
     if ($version =~ /^[^0-9]*(\d{1,2})(\.[0-9]+)*[^0-9]*$/) {
        if ($1 >= 2) {
           $result = $AMAZONLINUX_GENERIC . ' ' . $1;
        }
     }
   }

   return $result;
}

#...............................................................................
#
# CustomizeDNSFromDHCP
#
#     Sets whether dhcp should overwrite resolv.conf and thus supply the dns servers.
#
#
# Params & Result:
#     None
#
# Per https://aws.amazon.com/cn/premiumsupport/knowledge-center/ec2-static-dns-ubuntu-debian/
# , domain-search option is used to supersede/append with specific domains and
# multiple domains could be seperated by comma.
# Example:
#    append domain-search "xxx.xxx.xxx.xxx", "xxx.xxx.xxx.xxx";
#
#...............................................................................
sub CustomizeDNSFromDHCP
{
   my ($self) = @_;

   if (-e "/sbin/dhclient-script" or -e $self->DHClientConfPath()) {
      my $dnsFromDHCP = $self->{_customizationConfig}->Lookup("DNS|DNSFROMDHCP");
      my $dhclientDomains = $self->{_customizationConfig}->GetDNSSuffixes();

      if ($dnsFromDHCP =~ /no/i) {
            # Overwrite the dhcp answer.
            if (@$dhclientDomains) {
               Utils::AddOrReplaceInFile(
                  $self->DHClientConfPath(),
                  "supersede domain-search ",
                  "supersede domain-search ".join("," , map { "\"$_\""} @$dhclientDomains).";",
                  $Utils::SMDONOTSEARCHCOMMENTS);
            }

            my $dhclientServers = $self->{_customizationConfig}->GetNameServers();

            if (@$dhclientServers) {
               Utils::AddOrReplaceInFile(
                  $self->DHClientConfPath(),
                  "supersede domain-name-servers ",
                  "supersede domain-name-servers ".join("," , @$dhclientServers).";",
                  $Utils::SMDONOTSEARCHCOMMENTS);
            }
      } elsif ($dnsFromDHCP =~ /yes/i) {
         Utils::AddOrReplaceInFile(
            $self->DHClientConfPath(),
            "supersede domain-search ",
            "",
            $Utils::SMDONOTSEARCHCOMMENTS);

         Utils::AddOrReplaceInFile(
            $self->DHClientConfPath(),
            "supersede domain-name-servers ",
            "",
            $Utils::SMDONOTSEARCHCOMMENTS);

         if (@$dhclientDomains) {
            Utils::AddOrReplaceInFile(
               $self->DHClientConfPath(),
               "append domain-search ",
               "append domain-search ".join("," , map { "\"$_\""} @$dhclientDomains).";",
               $Utils::SMDONOTSEARCHCOMMENTS);
         }
      }
   }
}

sub DHClientConfPath
{
   return "/etc/dhcp/dhclient.conf";
}


1;
