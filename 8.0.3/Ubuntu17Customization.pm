########################################################################################
#  Copyright 2019 VMware, Inc.  All rights reserved.
########################################################################################

package Ubuntu17Customization;

# Inherit from Ubuntu15Customization.
# This is used for a fallback route for Ubuntu 17.x/18.x/19.04 customization,
# when both netplan and network-manager are installed.
use base qw(Ubuntu15Customization);

use strict;
use Debug;

# Convenience variables
my $UBUNTURELEASEFILE      = "/etc/lsb-release";
my $UBUNTUSYSTEMDRESOLVEDCONF      = "/etc/systemd/resolved.conf";

sub DetectDistroFlavour
{
   my ($self) = @_;
   my $result = undef;

   if (-e $Customization::ISSUEFILE) {
      DEBUG("Reading issue file ... ");
      my $issueContent = Utils::ExecuteCommand("cat $Customization::ISSUEFILE");
      DEBUG($issueContent);
      if ($issueContent =~ /Ubuntu\s+(1[7-8]\.(04|10)|19\.04)/i) {
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
         if ($lsbContent =~ /DISTRIB_ID=Ubuntu/i and
	     $lsbContent =~ /DISTRIB_RELEASE=(1[7-8]\.(04|10)|19\.04)/) {
            $result = "Ubuntu $1";
         }
      }
   }

   return $result;
}


sub CustomizeResolvFile
{
   # Ubuntu 17.10 Desktop has no package 'resolvconf' installed by default
   #   - This leads to no DNS settings in the interface file
   # From Ubuntu 17.04, 'systemd-resolved' Network Name Resolution
   # manager takes charge of DNS settings.
   #   - The DNS settings are determined from the global settings in the
   #     /etc/systemd/resolved.conf file
   #   - /etc/resolv.conf is symlinked to
   #     /run/systemd/resolve/stub-resolv.conf which is managed by
   #     systemd-resolved
   # For DHCP IP customization, dhclient-script is always called, which
   # means /etc/resolv.conf will be updated from dhclient.conf.
   # For static IP customization, dhclient-script is never called, so
   # update the global settings in /etc/systemd/resolved.conf file.

   my ($self) = @_;

   my $bootProto = $self->{_customizationConfig}->Lookup("NIC1|BOOTPROTO");
   if ($bootProto =~ /static/i) {
      my @content = Utils::ReadFileIntoBuffer($UBUNTUSYSTEMDRESOLVEDCONF);
      my @newContent;
      push(@newContent, "# Changed by VMware customization engine.\n");

      my $dnsSuffixes = $self->{_customizationConfig}->GetDNSSuffixes();
      my $dnsNameservers = $self->{_customizationConfig}->GetNameServers();
      foreach my $line (@content) {
         my $newLine = $line;
         if (($line =~ /^\#?DNS\=/i) &&
            $dnsNameservers && @$dnsNameservers) {
            $newLine = "DNS=" . join(' ', @$dnsNameservers) . "\n";
         }
         if (($line =~ /^\#?Domains\=/i) &&
             $dnsSuffixes && @$dnsSuffixes) {
            $newLine = "Domains=" . join(' ', @$dnsSuffixes) . "\n";
         }
         push(@newContent, $newLine);
      }
      # Update the 'systemd-resolved' configuration file
      Utils::WriteBufferToFile($UBUNTUSYSTEMDRESOLVEDCONF, \@newContent);
      # Flush local DNS caches
      Utils::ExecuteCommand("systemd-resolve --flush-caches 2>&1");
   }
}

sub RestartNetwork
{
   my ($self) = @_;
   $self->SUPER::RestartNetwork();
   # Restart 'systemd-resolved' service to make DNS updated without reboot
   Utils::ExecuteCommand("systemctl restart systemd-resolved.service 2>&1");
};

1;
