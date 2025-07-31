#!/usr/bin/perl

################################################################################
#  Copyright (c) 2015-2025 Broadcom. All Rights Reserved.
#  Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
#  and/or its subsidiaries.
################################################################################

#...............................................................................
#
# Customization.pm
#
#  This module implements a framework for OS customization.
#
#...............................................................................

package Customization;

use strict;
use Debug;
use Utils qw();
use StdDefinitions qw();
use TimezoneDB qw();

# By design GOSC normally should be executed within 1-5 sec, because it affects
# the provisioning time. The absolute pessimistic scenario is 100 sec currently
# hard-coded in linuxDeployment.c. To achieve that we don't want any individual
# command to take longer than 5 sec.
our $MAX_CMD_TIMEOUT = 5;

# Network specific
our $HOSTNAMEFILE          = "/etc/HOSTNAME";
our $HOSTSFILE             = "/etc/hosts";
our $RESOLVFILE            = "/etc/resolv.conf";

# Distro detection configuration files
our $ISSUEFILE             = "/etc/issue";

# Password specific
our $SHADOW_FILE = '/etc/shadow';
our $SHADOW_FILE_COPY = "$SHADOW_FILE.copy";

# Post-customization specific
our $CUSTOMIZATION_TMP_DIR                   = "/tmp/.vmware/linux/deploy";
our $POST_CUSTOMIZATION_TMP_DIR              = "/root/.customization";
our $POST_CUSTOMIZATION_TMP_RUN_SCRIPT_NAME  = "$POST_CUSTOMIZATION_TMP_DIR/post-customize-guest.sh";
our $POST_CUSTOMIZATION_TMP_SCRIPT_NAME      = "$POST_CUSTOMIZATION_TMP_DIR/customize.sh";

our $POST_REBOOT_PENDING_MARKER              = "/.guest-customization-post-reboot-pending";

our $runPostCustomizationBeforeReboot        = 1;
our $POST_CUSTOMIZATION_AGENT                = "/etc/init.d/post-customize-guest";
our $POST_CUSTOMIZATION_SCRIPT_SERVICE       = "post-customize.service";
our $POST_CUSTOMIZATION_AGENT_UNIT_FILE
       = "/etc/systemd/system/$POST_CUSTOMIZATION_SCRIPT_SERVICE";

our $CONFGROUPNAME_GUESTCUSTOMIZATION = "deployPkg";
our $CONFNAME_GUESTCUSTOMIZATION_ENABLE_CUSTOM_SCRIPTS = "enable-custom-scripts";

# machine-id
our $MACHINE_ID = "/etc/machine-id";
our $DBUS_MACHINE_ID = "/var/lib/dbus/machine-id";

#...............................................................................
#
# new
#
#     Constructor
#
# Input:
#     None
#
# Result:
#     Returns the customization object.
#
#...............................................................................

sub new
{
   my $class = shift;
   my $self = {};
   # Initialize the result to CUST_GENERIC_ERROR, so that if any lower layer
   # code throws an exception, the result correctly reflects an error.
   $self->{_customizationResult} = $StdDefinitions::CUST_GENERIC_ERROR;
   bless $self, $class;
   return $self;
}

#...............................................................................
#
# DetectDistro
#
#     Detects the OS distro.
#
# Input:
#     None
#
# Result:
#     Returns the distro name if supported by the customization object, otherwise undef.
#
#...............................................................................

sub DetectDistro
{
   die "DetectDistro not implemented";
}

#...............................................................................
#
# DetectDistroFlavour
#
#     Detects the flavour of the distribution.
#     Currently no decision is based on the flavour.
#     Must be called after the distro is detected by DetectDistro method.
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
   die "DetectDistroFlavour not implemented";
}

#...............................................................................
#
# Customize
#
#     Customizes the guest using the passed customization configuration.
#     Must be called after the distro is detected by DetectDistro method.
#
# Params:
#     $customizationConfig  ConfigFile instance
#     $directoryPath        Path to the root of the deployed package
#
# Result:
#     None.
#
#...............................................................................

sub Customize
{
   my ($self, $customizationConfig, $directoryPath) = @_;

   $self->{_customizationResult} = $StdDefinitions::CUST_GENERIC_ERROR;

   if (defined $customizationConfig) {
      $self->{_customizationConfig} = $customizationConfig;
   } else {
      die "Customize called with an undefined customization configuration";
   }

   $self->InitGuestCustomization();

   $self->CustomizeGuest($directoryPath);

   $self->{_customizationResult} = $StdDefinitions::CUST_SUCCESS;
}

#...............................................................................
#
# RefreshNics
#
#     Refresh the Nics in the kernel.
#     The instant cloned VM shall get new MAC addresses. However, the guest
#     kernel still caches the old MAC addresses. The function does the
#     refresh.
#     Note: reloading the driver does not always work. Experiments show
#     that the driver reload method works for e1000 but not for vmxnet, and
#     vmxnet3.
#     The proven method is to use the /sys virtual file system to achieve the
#     MAC refresh.
#
# Params:
#     $self  this object.
#
# Result:
#     Sets _customizationResult to a specific code in case of error.
#
#...............................................................................
sub RefreshNics
{
   my ($self) = @_;

   my @netFiles = </sys/class/net/*>;

   foreach my $netPath (@netFiles) {
      if (not -l "$netPath/device") {
         # Skip virtual interfaces such as vpn, lo, and vmnet1/8
         next;
      }
      my $dev = Utils::ExecuteCommand("readlink -f \"$netPath/device\"");
      $dev = Utils::Trim($dev);

      my $busid = Utils::ExecuteCommand("basename \"$dev\"");
      $busid = Utils::Trim($busid);

      my $driverPath = Utils::ExecuteCommand("readlink -f \"$dev/driver\"");
      $driverPath = Utils::Trim($driverPath);

      Utils::ExecuteCommand("echo $busid > \"$driverPath\"/unbind");
      Utils::ExecuteCommand("echo $busid > \"$driverPath\"/bind");

      # TBD: Add verification once VC can pass down the new MAC addresses.
   }
}

#...............................................................................
#
# InstantCloneCustomize
#
#     InstantClone flavor of Guest Customization.
#
# Params:
#     $customizationConfig  ConfigFile instance
#     $directoryPath        Path to the guest customization scripts
#
# Result:
#     Sets _customizationResult to a specific code in case of error.
#
#...............................................................................

sub InstantCloneCustomize
{
   my ($self, $customizationConfig, $directoryPath) = @_;

   $self->{_customizationConfig} = $customizationConfig;
   $self->InitGuestCustomization();

   # PR 2697617, renew the /etc/machine-id to avoid the child VMs having
   # the same machine-id as the parent VM.
   INFO("Refreshing machine-id ... ");
   eval {
      $self->RenewMachineID();
   }; if ($@) {
      $self->{_customizationResult} =
         $StdDefinitions::CUST_MACHINE_ID_RENEW_ERROR;
      die $@;
   }

   INFO("Refreshing MAC addresses ... ");
   eval {
      $self->RefreshNics();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_NIC_REFRESH_ERROR;
      die $@;
   }

   INFO("Customizing network settings ... ");
   eval {
      $self->ReadNetwork();
      $self->CustomizeNetwork();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_NETWORK_ERROR;
      die $@;
   }

   INFO("Customizing NICS ... ");
   eval {
      $self->CustomizeNICS();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_NIC_ERROR;
      die $@;
   }

   eval {
      INFO("Customizing the hosts file ... ");
      $self->CustomizeHostsFile($HOSTSFILE);

      INFO("Customizing DNS ... ");
      $self->CustomizeDNS();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_DNS_ERROR;
      die $@;
   }

   eval {
      INFO("Customizing date and time ... ");
      $self->CustomizeDateTime();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_DATETIME_ERROR;
      die $@;
   }

   # Customization of password not required, TBD XXX

   $self->{_customizationResult} = $StdDefinitions::CUST_SUCCESS;
}

#...............................................................................
#
# InitGuestCustomization
#
#    This method is called prior to the customization.
#
# Params:
#     None
#
# Result:
#     None
#
#...............................................................................

sub InitGuestCustomization
{
   my ($self) = @_;

   Utils::ExecuteCommand("perl --version");

   $self->{_oldHostnameCmd} = Utils::ExecuteCommand('hostname 2>/dev/null');
   chomp ($self->{_oldHostnameCmd});

   $self->{_oldResolverFQDN} = GetResolverFQDN();

   $self->InitOldHostname();
}

#...............................................................................
#
# InitOldHostname
#
#    This method inits the old host name taken from config file.
#
# Params:
#     None
#
# Result:
#     None
#
#...............................................................................

sub InitOldHostname
{
   die "InitOldHostname not implemented";
}

#...............................................................................
#
# CustomizePassword
#
#    Sets and/or resets root password.
#
# Params:
#    $currDir     Path to the root of the deployed package
#
# Result:
#    None
#
#...............................................................................

sub CustomizePassword
{
   my ($self, $currDir) = @_;
   my $exitCode;
   my $setPassword = 1;

   $currDir = "$currDir/scripts";

   my $resetPassword = $self->{_customizationConfig}->GetResetPassword();
   my $adminPassword = $self->{_customizationConfig}->GetAdminPassword();

   if (!defined $adminPassword) {
      $setPassword = 0;
   }
   if ($setPassword == 1 || $resetPassword == 1) {
      INFO("Changing the password...");
      Utils::ExecuteCommand("$Utils::CP -f $SHADOW_FILE $SHADOW_FILE_COPY");
      # resetpwd.awk was part of Toledo and T2 VCD releases and copied "as is"
      # it operates in temporary files and provides 5 ways to change/reset root password
      Utils::ExecuteCommand(
         "$Utils::AWK -v expirepassword=$resetPassword -v setpassword=$setPassword -v password=$adminPassword -f ${currDir}/resetpwd.awk $SHADOW_FILE_COPY",
         'password utils',
         \$exitCode,
         1); #secure
      if ($exitCode != 0) {
         die "Unable to expire password for root users OR set password for root user";
      }
      Utils::ExecuteCommand("$Utils::RM $SHADOW_FILE_COPY");
      INFO("Changing the password is complete");
   } else {
      INFO("Changing password is not needed");
   }
}

#...............................................................................
#
# InstallPostRebootAgentInSysV
#
#    Installs post-reboot customization agent in sysV init.
#
# Params:
#    $currDir     Path to the root of the deployed package
#
# Result:
#    None
#
#...............................................................................
sub InstallPostRebootAgentInSysV
{
   my ($self, $currDir) = @_;

   INFO("Installing post-reboot customization agent in SysV from '$currDir'...");
   if(not -e $POST_CUSTOMIZATION_AGENT) {
      INFO("Installing agent service");
      my $PostCust = "$currDir/scripts/post-customize-guest.sh";
      Utils::ExecuteCommand("$Utils::CP $PostCust $POST_CUSTOMIZATION_AGENT");
      Utils::ExecuteCommand("$Utils::CHMOD u+x $POST_CUSTOMIZATION_AGENT");
   } else {
      INFO("Agent service is already installed");
   }

   INFO("Installing post-reboot customization agent in SysV finished");
}

sub EnablePostRebootAgentByChkconfig
{
   my ($self) = @_;
   INFO("Enabling post-reboot customization agent by chkconfig");
   my $exitCode;
   Utils::ExecuteCommand("chkconfig --add post-customize-guest",
                         "chkconfig add",
                         \$exitCode);
   if ($exitCode eq 0) {
      $runPostCustomizationBeforeReboot = 0;
   } else {
      $self->EnablePostRebootAgentManually();
   }
}

sub EnablePostRebootAgentManually
{
   INFO("Enabling post-reboot customization agent manually");
   if(!(-e "/etc/rc2.d"&& -e "/etc/rc3.d"&& -e "/etc/rc4.d"&& -e "/etc/rc5.d")) {
      return;
   }
   INFO("Adding it in runlevel 3, 5 and with priority 99");

   my $cmd3="ln -sf $POST_CUSTOMIZATION_AGENT /etc/rc3.d/S99post-customize-guest";
   my $cmd5="ln -sf $POST_CUSTOMIZATION_AGENT /etc/rc5.d/S99post-customize-guest";
   Utils::ExecuteCommand($cmd3);
   Utils::ExecuteCommand($cmd5);
   $runPostCustomizationBeforeReboot = 0;
}

#...............................................................................
#
# InstallPostRebootAgentInSystemd
#
#    Installs post-reboot customization agent in systemd init.
#
# Params:
#    $currDir     Path to the root of the deployed package
#
# Result:
#    None
#
#...............................................................................
sub InstallPostRebootAgentInSystemd
{
   my ($self, $currDir) = @_;

   INFO("Installing post-reboot customization agent in systemd init from '$currDir'...");
   my $PostCust = "$currDir/scripts/post-customize-guest.sh";
   Utils::ExecuteCommand("$Utils::CP $PostCust $POST_CUSTOMIZATION_TMP_RUN_SCRIPT_NAME");
   if (!-e $POST_CUSTOMIZATION_AGENT_UNIT_FILE) {
      INFO("Creating post-customize unit file $POST_CUSTOMIZATION_AGENT_UNIT_FILE...");
      my $inStr;
      Utils::ExecuteCommand("$Utils::TOUCH $POST_CUSTOMIZATION_AGENT_UNIT_FILE");
      $inStr = "[Unit]";
      Utils::ExecuteCommand(
         "$Utils::ECHO \"$inStr\" >>$POST_CUSTOMIZATION_AGENT_UNIT_FILE");
      $inStr = "Description=Run post-customization script";
      Utils::ExecuteCommand(
         "$Utils::ECHO \"$inStr\" >>$POST_CUSTOMIZATION_AGENT_UNIT_FILE");
      $inStr = "[Service]";
      Utils::ExecuteCommand(
         "$Utils::ECHO \"$inStr\" >>$POST_CUSTOMIZATION_AGENT_UNIT_FILE");
      $inStr = "Type=idle";
      Utils::ExecuteCommand(
         "$Utils::ECHO \"$inStr\" >>$POST_CUSTOMIZATION_AGENT_UNIT_FILE");
      $inStr = "ExecStart=$Utils::SH $POST_CUSTOMIZATION_TMP_RUN_SCRIPT_NAME";
      Utils::ExecuteCommand(
         "$Utils::ECHO \"$inStr\" >>$POST_CUSTOMIZATION_AGENT_UNIT_FILE");
      $inStr = "[Install]";
      Utils::ExecuteCommand(
         "$Utils::ECHO \"$inStr\" >>$POST_CUSTOMIZATION_AGENT_UNIT_FILE");
      $inStr = "WantedBy=multi-user.target";
      Utils::ExecuteCommand(
         "$Utils::ECHO \"$inStr\" >>$POST_CUSTOMIZATION_AGENT_UNIT_FILE");
   } else {
      INFO("$POST_CUSTOMIZATION_AGENT_UNIT_FILE exists, no need to create it.");
   }
   my $enable = "systemctl enable $POST_CUSTOMIZATION_SCRIPT_SERVICE>/dev/null 2>&1";
   Utils::ExecuteCommand("$enable");
   my $isEnabled = "systemctl is-enabled $POST_CUSTOMIZATION_SCRIPT_SERVICE";
   my $PostCustServiceEnabled = Utils::Trim(Utils::ExecuteCommand($isEnabled));
   if ($PostCustServiceEnabled eq "enabled") {
      $runPostCustomizationBeforeReboot = 0;
      INFO("Installing post-reboot customization agent in systemd init finished");
   } else {
      ERROR("Installing post-reboot customization agent in systemd init failed");
   }
}

#...............................................................................
#
# IsSystemdEnabled
#
#    Check whether systemd is enabled and used as init process
#
# Result:
#    1: systemd is used as init process
#    0: systemd is not used as init process
#...............................................................................
sub IsSystemdEnabled
{
   my $cmd = "ps -p 1 | grep -so systemd | cat";
   my $UsingSystemd = Utils::Trim(Utils::ExecuteCommand($cmd));
   if ($UsingSystemd) {
      return 1;
   }
   return 0;
}

#...............................................................................
#
# IsChkconfigEnabled
#
#    Check whether chkconfig has been installed in OS
#
# Result:
#    1: chkconfig has been installed
#    0: chkconfig hasn't been installed
#...............................................................................
sub IsChkconfigEnabled
{
   my $cmd = "whereis chkconfig | grep -so 'chkconfig:.*chkconfig' |cat";
   my $UsingChkconfig = Utils::Trim(Utils::ExecuteCommand($cmd));
   if ($UsingChkconfig) {
      return 1;
   }
   return 0;
}

#...............................................................................
#
# InstallPostRebootAgent
#
#    Installs post-reboot customization agent unless it's already installed.
#
#    If init process is systemd, will use systemctl to install reboot agent.
#    Or the init process will be sysV, run InstallPostRebootAgentInSysV firstly,
#    and if chkconfig is available, use it, if not available, install reboot
#    agent manually.
#
# Params:
#    $currDir     Path to the root of the deployed package
#
# Result:
#    Sets the $runPostCustomizationBeforeReboot global variable.
#
#...............................................................................
sub InstallPostRebootAgent
{
   my ($self, $currDir) = @_;
   if ($self->IsSystemdEnabled()) {
      $self->InstallPostRebootAgentInSystemd($currDir);
   } else {
      $self->InstallPostRebootAgentInSysV($currDir);
      if ($self->IsChkconfigEnabled()) {
         $self->EnablePostRebootAgentByChkconfig();
      } else {
         $self->EnablePostRebootAgentManually();
      }
   }
}

#...............................................................................
#
# RunCustomScript
#
#    Handles the pre-/post-customization script if any.
#
#    Pre-customization is executed inline. Post-customization is normally
#    scheduled to be run after reboot.
#
# Params:
#    $customizationDir     Path to the root of the deployed package
#    $customizationType    'precustomization' or 'postcustomization'
#
# Result:
#    None
#
#...............................................................................

sub RunCustomScript
{
   my ($self, $customizationDir, $customizationType) = @_;

   INFO("RunCustomScript invoked in '$customizationDir' for '$customizationType'");

   my $scriptName = $self->{_customizationConfig}->GetCustomScriptName();
   my $exitCode;

   if (defined $scriptName) {
      my $scriptPath = "$customizationDir/$scriptName";

      if(-e $scriptPath) {
         # Strip any CR characters from the decoded script
         Utils::ExecuteCommand("$Utils::CAT $scriptPath | $Utils::TR -d '\r' > $scriptPath.tmp");
         Utils::ExecuteCommand("$Utils::MV $scriptPath.tmp $scriptPath");

         # Copy script to /root directory because customization dir
         # might mount with no-exec option
         if(not -d $POST_CUSTOMIZATION_TMP_DIR) {
            INFO("Making temporary post-customization directory");
            Utils::ExecuteCommand("$Utils::MKDIR $POST_CUSTOMIZATION_TMP_DIR");
         }
         Utils::ExecuteCommand(
            "$Utils::CP $scriptPath $POST_CUSTOMIZATION_TMP_SCRIPT_NAME");

         Utils::ExecuteCommand(
            "$Utils::CHMOD u+x $POST_CUSTOMIZATION_TMP_SCRIPT_NAME");

         if ($customizationType eq 'precustomization') {
            INFO("Executing pre-customization script...");
            #Do not specify shell interpreter, because it may bring in syntactic error
            Utils::ExecuteCommand(
               "$POST_CUSTOMIZATION_TMP_SCRIPT_NAME \"$customizationType\"",
               $customizationType,
               \$exitCode);
            if ($exitCode != 0) {
               die "Execution of $customizationType failed!";
            }
         } else { # post-customization

            $runPostCustomizationBeforeReboot = 1; # set global var
            $self->InstallPostRebootAgent($customizationDir);

            if ($runPostCustomizationBeforeReboot) {
               WARN("Executing post-customization script inline...");
               #Do not specify shell interpreter, because it may bring in syntactic error
               Utils::ExecuteCommand(
                  "$POST_CUSTOMIZATION_TMP_SCRIPT_NAME \"$customizationType\"",
                  $customizationType,
                  \$exitCode);
               if ($exitCode != 0) {
                  die "Execution of $customizationType failed!";
               }
            } else {
                  INFO("Scheduling post-customization script");

                  INFO("Creating post-reboot pending marker");
                  Utils::ExecuteCommand("$Utils::RM $POST_REBOOT_PENDING_MARKER");
                  Utils::ExecuteCommand("$Utils::TOUCH $POST_REBOOT_PENDING_MARKER");
            }
         }
      } else {
         WARN("Customization script '$scriptPath' does not exist");
      }
   } else {
      INFO("No customization script to run");
   }

   INFO("RunCustomScript has completed");
}

#...............................................................................
#
# SetupMarkerFiles
#
#    In case marker id is defined, deletes old markers and creates a new one.
#
# Params:
#    None
#
# Result:
#    None
#
#...............................................................................

sub SetupMarkerFiles
{
   my ($self) = @_;
   my $markerId = $self->{_customizationConfig}->GetMarkerId();

   if (!defined $markerId) {
      return;
   }

   my $markerFile = "/.markerfile-$markerId.txt";

   Utils::ExecuteCommand("$Utils::RM /.markerfile-*.txt");
   Utils::ExecuteCommand("$Utils::TOUCH $markerFile");
}

#...............................................................................
#
# CheckMarkerExists
#
#    Checks existence of marker file in case marker id is provided.
#
# Params:
#    None
#
# Result:
#    1 if marker file exists, 0 if not or undefined.
#
#...............................................................................

sub CheckMarkerExists
{
    my ($self) = @_;
    my $markerId = $self->{_customizationConfig}->GetMarkerId();

    if (!defined $markerId) {
       return 0;
    }

    my $markerFile = "/.markerfile-$markerId.txt";

    if (-e $markerFile) {
       return 1;
    } else {
       return 0;
    }
}

#...............................................................................
#
# CustomizeGuest
#
#    Executes the customization steps for the guest OS customization.
#
# Params:
#    $directoryPath     Path to the root of the deployed package
#
# Result:
#    None
#
#...............................................................................

sub CustomizeGuest
{
   my ($self, $directoryPath) = @_;

   my $markerId = $self->{_customizationConfig}->GetMarkerId();
   my $markerExists = $self->CheckMarkerExists();
   my $scriptName = $self->{_customizationConfig}->GetCustomScriptName();
   my $customizationSource =
      $self->{_customizationConfig}->GetCustomizationSource();

   if (defined $customizationSource) {
      INFO("Customization source: $customizationSource");
      # PR 2697617, if the customization source is VM clone, renew
      # /etc/machine-id to avoid the new VMs having the same machine-id as the
      # VM template.
      if ($customizationSource =~ /clone/) {
         eval {
            $self->RenewMachineID();
         }; if ($@) {
            $self->{_customizationResult} =
               $StdDefinitions::CUST_MACHINE_ID_RENEW_ERROR;
            die $@;
         }
      } else {
         INFO("No need to renew machine ID.");
      }
   }

   if (defined $markerId && !$markerExists) {
      if (defined $scriptName) {
         my $defaultVal = "false";
         # PR 2577996,by default enable-custom-script is false for security
         # reason. But vCD could change the default value to true by
         # setting DEFAULT-RUN-POST-CUST-SCRIPT to yes in customization config
         # file.
         if ($self->{_customizationConfig}->GetDefaultRunPostScript()) {
            $defaultVal = "true";
         }
         # PR2440031, check whether custom script is enabled in VM Tools.
         # By default it's disabled for security concern.
         my $custScriptsEnabled =
            Utils::GetToolsConfig($CONFGROUPNAME_GUESTCUSTOMIZATION,
               $CONFNAME_GUESTCUSTOMIZATION_ENABLE_CUSTOM_SCRIPTS,
               $defaultVal);
         if ($custScriptsEnabled =~ /false/i) {
            Utils::SetCustomizationStatusInVmx(
               $StdDefinitions::TOOLSDEPLOYPKG_RUNNING,
               $StdDefinitions::CUST_SCRIPT_DISABLED_ERROR);
            ERROR("User defined scripts execution is not enabled. " .
            "To enable it, please have vmware tools v10.1.0 or later " .
            "installed and execute the following cmd with root priviledge: " .
            "'vmware-toolbox-cmd config set deployPkg enable-custom-scripts " .
            " true' Or remove the script from the customization spec.");
            exit $StdDefinitions::CUST_SCRIPT_DISABLED_ERROR;
         }
      }

      INFO("Handling pre-customization ... ");
      eval {
         $self->RunCustomScript($directoryPath, 'precustomization');
      }; if ($@) {
         $self->{_customizationResult} = $StdDefinitions::CUST_PRE_CUSTOMIZATION_ERROR;
         die $@;
      }
   } else {
      INFO("Marker file exists or is undefined, pre-customization is not needed");
   }

   INFO("Customizing Network settings ... ");
   eval {
      $self->ReadNetwork();
      $self->CustomizeNetwork();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_NETWORK_ERROR;
      die $@;
   }

   INFO("Customizing NICS ... ");
   eval {
      $self->CustomizeNICS();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_NIC_ERROR;
      die $@;
   }

   eval {
      INFO("Customizing Hosts file ... ");
      $self->CustomizeHostsFile($HOSTSFILE);

      INFO("Customizing DNS ... ");
      $self->CustomizeDNS();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_DNS_ERROR;
      die $@;
   }

   eval {
      INFO("Customizing Date&Time ... ");
      $self->CustomizeDateTime();
   }; if ($@) {
      $self->{_customizationResult} = $StdDefinitions::CUST_DATETIME_ERROR;
      die $@;
   }

   if (defined $markerId && !$markerExists) {
      INFO("Handling password settings ... ");
      eval {
         $self->CustomizePassword($directoryPath);
      }; if ($@) {
         $self->{_customizationResult} = $StdDefinitions::CUST_PASSWORD_ERROR;
         die $@;
      }
   } else {
      INFO("Marker file exists or is undefined, password settings are not needed");
   }

   if (defined $markerId && !$markerExists) {
      INFO("Handling post-customization ... ");
      eval {
         $self->RunCustomScript($directoryPath, 'postcustomization');
      }; if ($@) {
         $self->{_customizationResult} = $StdDefinitions::CUST_POST_CUSTOMIZATION_ERROR;
         die $@;
      }
   } else {
      INFO("Marker file exists or is undefined, post-customization is not needed");
   }

   if (defined $markerId) {
      INFO("Handling marker creation ... ");
      eval {
         $self->SetupMarkerFiles();
      }; if ($@) {
         $self->{_customizationResult} = $StdDefinitions::CUST_MARKER_ERROR;
         die $@;
      }
   } else {
      INFO("Marker creation is not needed");
   }
}

#...............................................................................
# GetCustomizationResult
#
#   Returns the error code for customization failure.
#
# Params:
#   None
#
# Result:
#   An error code from StdDefinitions
#...............................................................................

sub GetCustomizationResult
{
   my ($self) = @_;
   return $self->{_customizationResult};
}

#...............................................................................
# ReadNetwork
#
#   Reads any relevant network settings
#
# Result & Params: None
#...............................................................................

sub ReadNetwork
{
   # do nothing
}

#...............................................................................
# CustomizeNetwork
#
#   Customizes the network setting
#
# Result & Params: None
#...............................................................................

sub CustomizeNetwork
{
   die "CustomizeNetwork not implemented";
}

#...............................................................................
#
# CustomizeNICS
#
#   Customize network interface. This is generic to all distribution as we know.
#
# Params & Result:
#   None
#
# NOTE:
#...............................................................................

sub CustomizeNICS
{
   my ($self) = @_;

   # pcnet32 NICs fail to get a device name following a tools install. Refer PR
   # 29700: http://bugzilla/show_bug.cgi?id=29700 Doing a modprobe here solves
   # the problem for this boot.

   my $modproberesult = Utils::ExecuteCommand("modprobe pcnet32 2> /dev/null");

   # When doing the first boot up, "ifconfig -a" may only display information
   # about the loopback interface -- bug ? Doing an "ifconfig ethi" once seems
   # to wake it up.

   my $ifcfgresult = Utils::ExecuteCommand("/sbin/ifconfig eth0 2> /dev/null");

   # get information on the NICS to configure
   my $nicsToConfigure = $self->{_customizationConfig}->Lookup("NIC-CONFIG|NICS");

   # split the string by ","
   my @nics = split(/,/, $nicsToConfigure);

   INFO("Customizing NICS. { $nicsToConfigure }");

   # iterate through each NIC
   foreach my $nic (@nics) {
      INFO("Customizing NIC $nic");
      $self->CustomizeSpecificNIC($nic);
   }
};

#...............................................................................
#
# CustomizeSpecificNIC
#
#   Customize an interface.
#
# Params:
#   $nic    NIC name as specified in the config file like NIC-LO
#
# Returns:
#   None
#
# NOTE:
#
#...............................................................................

sub CustomizeSpecificNIC
{
   my ($self, $nic) = @_;

   # get the interface
   my $macaddr = $self->{_customizationConfig}->Lookup($nic . "|MACADDR");
   my $interface = $self->GetInterfaceByMacAddress($macaddr);

   if (!$interface) {
      die "Error finding the specified NIC (MAC address = $macaddr)";
   };

   INFO ("Writing ifcfg file for NIC suffix = $interface");

   # write to config file
   my @content = $self->FormatIFCfgContent($nic, $interface);
   unshift(@content, "# Generated by VMWare customization engine.\n");
   my $ifConfigFile = $self->IFCfgFilePrefix() . $interface;
   Utils::WriteBufferToFile($ifConfigFile, \@content);
   Utils::SetPermission($ifConfigFile, $Utils::RWRR);

   # set up the gateways -- routes for addresses outside the subnet
   # GATEWAY parameter is not used to support multiple gateway setup
   my @ipv4Gateways =
      split(/,/, $self->{_customizationConfig}->Lookup($nic . "|GATEWAY"));
   my @ipv6Gateways =
      ConfigFile::ConvertToArray(
         $self->{_customizationConfig}->Query("^$nic(\\|IPv6GATEWAY\\|)"));

   if (@ipv4Gateways || @ipv6Gateways) {
      $self->AddRoute($interface, \@ipv4Gateways, \@ipv6Gateways, $nic);
   }
}

#...............................................................................
#
# GetInterfaceByMacAddress
#
#   Get the interface for the network card based on the MAC address. This is
#   like querying for the interface based on MAC address. This information is
#   present in /proc/sys/net but unfortunately in binary format. So, we have to
#   use ifconfig output to extract it.
#
# Params:
#   $macAddress     Mac address as hex value separated by ':'
#   $ifcfgResult    Optional. The ifconfig output
#
# Returns:
#   The interface for this mac address
#   or
#   undef if the mac address cannot be mapped to interface
#
# NOTE: /sbin/ifconfig should be available in the guest.
#...............................................................................

sub GetInterfaceByMacAddress
{
   my ($self, $macAddress, $ifcfgResult) = @_;

   if (! defined $ifcfgResult) {
      $ifcfgResult = Utils::ExecuteCommand('/sbin/ifconfig -a');
   }

   my $result = undef;

   my $macAddressValid = ($macAddress =~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i);

   if ($macAddressValid &&
      ($ifcfgResult =~ /^\s*(\w+?)(:\w*)?\s+.*?$macAddress/mi)) {
      $result = $1;
   }

   return $result;
}

sub GetInterfaceByMacAddressIPAddrShow
{
   # This function is same as GetInterfaceByMacAddress but uses
   # '/sbin/ip addr show' instead of/sbin/ifconfig

   my ($self, $macAddress, $ipAddrResult) = @_;
   my $result = undef;
   if (! defined $ipAddrResult) {
      my $ipPath = Utils::GetIpPath();
      if ( defined $ipPath){
         $ipAddrResult = Utils::ExecuteCommand("$ipPath addr show 2>&1");
      } else {
         WARN("Path to 'ip addr' not found.");
      }
   }

   my $macAddressValid = ($macAddress =~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i);

   # output of /usr/sbin/ip addr show in RHEL7 is
   # 1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN
   # link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
   # inet 127.0.0.1/8 scope host lo
   #    valid_lft forever preferred_lft forever
   # inet6 ::1/128 scope host
   #    valid_lft forever preferred_lft forever
   # 2: ens192: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP qlen 1000
   # link/ether 00:50:56:af:67:d2 brd ff:ff:ff:ff:ff:ff
   # inet 10.20.116.200/22 brd 10.20.119.255 scope global ens192
   #    valid_lft forever preferred_lft forever
   # inet6 fc00:10:20:119:250:56ff:feaf:67d2/128 scope global dynamic
   #    valid_lft 2573184sec preferred_lft 2573184sec
   #
   # output of /usr/sbin/ip addr show when both dev_addr and perm_addr exist in
   # SLES15 SP4
   # 1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
   # link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
   # inet 127.0.0.1/8 scope host lo
   #    valid_lft forever preferred_lft forever
   # inet6 ::1/128 scope host
   #    valid_lft forever preferred_lft forever
   # 3: eth0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc mq state DOWN group default qlen 1000
   # link/ether 00:50:56:83:31:e5 brd ff:ff:ff:ff:ff:ff permaddr 00:50:56:83:98:dc
   # altname enp11s0
   # altname ens192

   if ($macAddressValid) {
      if ($ipAddrResult =~
         /^\d+:\s([^\s.:]+):\s[^\n]+[^\n]+\s+link\/\w+\s+$macAddress/mi) {
         $result = $1;
      } elsif ($ipAddrResult =~
         /^\d+:\s([^\s.:]+):\s[^\n]+\s+link\/\w+\s+[^\n]+permaddr\s+$macAddress/mi) {
         $result = $1;
      }
   }

   return $result;
}

#...............................................................................
#
# FormatIFCfgContent
#
#   Formats the contents of the ifcfg-<interface> file.
#
# Params:
#   $nic
#   $interface
#
# Returns:
#   Array with formatted lines.
#
# NOTE:
#
#...............................................................................

sub FormatIFCfgContent
{
   die "FormatIFCfgContent not implemented";
}

#...............................................................................
#
# AddRoute
#
# Add a route (gateway) for the guest w.r.t a given NIC.
#
# Params:
#     $destination   The gateway IP address(es)
#     $nicname       Prefix of the NIC
#
# Return:
#     None.
#
#...............................................................................

sub AddRoute
{
   die "AddRoute not implemented";
}

#...............................................................................
# BuildFQDN
#
# Build the FQDN to the right value
#
# Params:
#     #newHostnameFQDN       The new Hostname FQDN
#     $newDomainname         The domain name
#
# Return:
#     The new FQDN
#...............................................................................
sub BuildFQDN
{
   my ($self, $newHostnameFQDN, $newDomainname) = @_;
   DEBUG("Building FQDN. HostnameFQDN: $newHostnameFQDN, Domainname: $newDomainname");
   my $newFQDN;
   my $lengthHostnameFQDN = length ($newHostnameFQDN);
   my $lengthDomainname = length ($newDomainname);

   my $rInd = rindex($newHostnameFQDN, ".$newDomainname");
   my $pos = $lengthHostnameFQDN - $lengthDomainname - 1;

   if ($newDomainname eq "") {
        $newFQDN = "$newHostnameFQDN";
   } elsif ($rInd == -1 || $rInd != $pos) {
        $newFQDN = "$newHostnameFQDN.$newDomainname";
   } else {
        # Domainname is already included in the hostname as required by certain programs.
        # In the normal case the hostname is not expected to contain domainname or any dots for that matter.
        $newFQDN = "$newHostnameFQDN";
   }

   return $newFQDN;
}

#...............................................................................
#
# CustomizeHostsFile
#
#     Hosts file is the static host lookup. If appropriately configured this
#     preceeds the DNS lookup. Customization process removes all reference for
#     the old hostname and replaces it with the new host name. It also adds
#     ethernet IPs as reference to the host name.
#
# Params & Result:
#     None
#
# NOTE: No support for IPv6 entries.
# TODO: What about IP settings from the old ethernets ?
#
#...............................................................................

sub CustomizeHostsFile
{
   my ($self, $hostsFile) = @_;

   # Partial customization - calculate new hostname and new FQDN
   # based on the existing values and new customization spec values

   # Retrieve old hostname and FQDN
   my $oldHostname = $self->OldHostnameCmd();
   my $oldFQDN = $self->OldFQDN();
   DEBUG("Old hostname=[$oldHostname]");
   DEBUG("Old FQDN=[$oldFQDN]");

   my $cfgHostname = $self->{_customizationConfig}->GetHostName();
   my $newHostname = $cfgHostname;
   # FQDN may not include hostname, prepare to preserve FQDN
   my $newHostnameFQDN = $cfgHostname;
   if (ConfigFile::IsKeepCurrentValue($cfgHostname)) {
      $newHostname = $oldHostname;
      $newHostnameFQDN = Utils::GetShortnameFromFQDN($oldFQDN);

      # Old hostname is not resolved and hence old FQDN is not available
      # Use hostname as new FQDN
      if (! $newHostnameFQDN) {
         $newHostnameFQDN = $oldHostname;
      }
   }
   DEBUG("New hostname=[$newHostname]");
   if (! $newHostname) {
      # Cannot create new hostname as old one is invalid
      die 'Invalid old hostname';
   }

   my $cfgDomainname = $self->{_customizationConfig}->GetDomainName();
   my $newDomainname = $cfgDomainname;
   if (ConfigFile::IsKeepCurrentValue($cfgDomainname)) {
      $newDomainname = Utils::GetDomainnameFromFQDN($oldFQDN);
   } elsif (ConfigFile::IsRemoveCurrentValue($newDomainname)) {
      $newDomainname = '';
   }
    my $newFQDN = $self->BuildFQDN($newHostnameFQDN , $newDomainname);
   DEBUG("New FQDN=[$newFQDN]");

   my @newContent;
   my $hostnameSet = 0;
   my $ipv6LoopbackHostnameSet = 0;

   # Algorithm overview
   # 1.Do not modify '127... ...' and '::1' entries unless oldhostname is there: programs may fail
   # 2.Do not replace a localhost: localhost should always remain
   # 3.Remove non loopback entries with old hostname (assuming this is the old ip)
   # 4.Remove non loopback entries with new hostname if already there
   # 5.Setting hostname does only replacements of oldhostname
   # 6.Setting FQDN does an insert as first name because FQDN should be there
   # 7.Add new line that is <newip> <newhostname>, if <newip> is available
   # 8.Unless new hostname is set by (5) or (7) add a 127.0.1.1 <newhostname> entry

   foreach my $inpLine (Utils::ReadFileIntoBuffer($hostsFile)) {
      DEBUG("Line (inp): $inpLine");
      my $line = Utils::GetLineWithoutComments($inpLine);

      if ($line =~ /^\s*(\S+)\s+(.*)/) {
         my %lineNames = map {$_ => 1} split(/\s+/, $2);
         my $ip = $1;
         my $isIpv6Loopback = ($ip =~ /^[0|:][0|:]+1$/);
         my $isLoopback =
            (($ip =~ /127\./) || $isIpv6Loopback);

         if ($isLoopback) {
            my $newLine = $line;
            chomp($newLine);

            # LOOPBACK - REPLACE all non-localhost old hostnames with new hostname
            if (exists $lineNames{$oldHostname} &&
                !ConfigFile::IsKeepCurrentValue($cfgHostname) &&
                !($oldHostname eq 'localhost') &&
                !($oldHostname eq 'localhost.localdomain') ) {
               DEBUG("Replacing [$oldHostname]");
               $newLine = join(
                  ' ',
                  map { $_ eq $oldHostname ? $newHostname : $_  }
                      split(/\s/, $newLine));
            }

            my $newLineContainsNewhostname = ($newLine =~ /\s+$newHostname(\s+|$)/);
            $hostnameSet ||= $newLineContainsNewhostname;

            if ($newLineContainsNewhostname) {
               # LOOPBACK with new hostname - REPLACE all old FQDN with new FQDN
               if (!($oldFQDN eq $newHostname)) {
                  # Don't replace new hostname
                  DEBUG("Replacing [$oldFQDN]");
                  $newLine = join(
                     ' ',
                     map { $_ eq $oldFQDN ? $newFQDN : $_  }
                        split(/\s/, $newLine));
               }

               # LOOPBACK with new hostname - INSERT new FQDN as first name
               if ($newLine =~ /^\s*(\S+)\s+(.*)/) {
                  my ($ip, $aliases) = ($1, $2);
                  DEBUG("Adding [$newFQDN]");
                  # New FQDN is not the first name
                  if ($aliases !~ /^$newFQDN(\s|$)/) {
                     # Make it
                     $newLine = "$ip\t$newFQDN $aliases";
                  }
               }

               # LOOPBACK with new hostname - REMOVE duplicates of FQDN from aliases
               if ($newLine =~ /^\s*(\S+)\s+(\S+)\s(.*)/) {
                  my ($ip, $fqdn, $aliases)    = ($1, $2, $3);
                  DEBUG("Removing duplicating FQDNs");
                  my @aliases = split(/\s/, $aliases);
                  $newLine = "$ip\t$fqdn " . join(' ', grep { !($_ eq $fqdn) } @aliases);
               }
            }

            push(@newContent, "$newLine\n");
         } elsif (! (exists $lineNames{$oldHostname}) &&
                  ! (exists $lineNames{$newHostname})) {
            # NONLOOPBACK - Leave entries to hosts different from:
            #     - old hostname
            #     - new hostname
            push(@newContent, $inpLine);
         }
      } else {
         # Leave comments
         push(@newContent, $inpLine);
      }
   }

   # Add mapping to the customized static ip
   my $newStaticIPEntry;
   foreach my $nic ($self->{_customizationConfig}->GetNICs()) {
      my $ipaddr = $self->{_customizationConfig}->Lookup($nic . "|IPADDR");

      if ($ipaddr) {
         $newStaticIPEntry = "$ipaddr\t$newFQDN";
         if (! ($newFQDN eq $newHostname)) {
            $newStaticIPEntry .= " $newHostname";
         }

         DEBUG("Static ip entry added");
         push(@newContent, "\n$newStaticIPEntry\n");
         $hostnameSet = 1;

         last;
      }
   }

   # Add mapping to loopback 127.0.1.1 if new hostname is still not set
   if (! $hostnameSet) {
      # Hostname still not added - use a loopback entry to
      # create mapping

      my $newLine = "127.0.1.1\t$newFQDN";
      if (! ($newFQDN eq $newHostname)) {
         $newLine .= " $newHostname";
      }

      DEBUG("Loopback entry added");
      Utils::ReplaceOrAppendInLines("127.0.1.1", "\n$newLine\n",\@newContent);
   }

   foreach (@newContent) {
      DEBUG("Line (out): $_");
   }

   Utils::WriteBufferToFile($hostsFile, \@newContent);
   Utils::SetPermission($hostsFile, $Utils::RWRR);
}

#...............................................................................
#
# CustomizeDNS
#
#     Customizes the DNS settings for the guest
#
# Params & Result:
#     None
#
#...............................................................................

sub CustomizeDNS
{
   my ($self) = @_;

   $self->CustomizeNSSwitch("hosts");
   $self->CustomizeResolvFile();
   $self->CustomizeDNSFromDHCP();
}

#...............................................................................
#
# CustomizeNSSwitch
#
#     Add dns to the nsswitch.conf file. This basically includes dns in
#     the resolving mechanism.
#
# Params
#     $database   To which database to add the dns
#
# Result
#
#...............................................................................

sub CustomizeNSSwitch
{
   my ($self, $database) = @_;

   my $nsswitchFileName = "/etc/nsswitch.conf";
   my @content = Utils::ReadFileIntoBuffer ($nsswitchFileName);
   my $databaseLineIndex =
      Utils::FindLineInBuffer (
         $database,
         \@content,
         $Utils::SMDONOTSEARCHCOMMENTS);

   if ($databaseLineIndex >= 0) {
      # Rewrite line with chopped comment from end-of-line, because it is used by dhcp to delete the line when turned off.
      my $databaseLine = Utils::GetLineWithoutComments($content[$databaseLineIndex]);
      chomp $databaseLine;

      $content[$databaseLineIndex] =
         ($databaseLine =~ /\bdns\b/i) ?
            $databaseLine . "\n" :
            $databaseLine . " dns\n";
   } else {
      push(@content, "$database: files dns\n");
   }

   Utils::WriteBufferToFile($nsswitchFileName, \@content);
   Utils::SetPermission($nsswitchFileName, $Utils::RWRR);
}

#...............................................................................
#
# CustomizeResolvFile
#
#     Replaces the resolv.conf file with the  following
#
#     1. Search (Usually contains the local domain)
#     2. List of nameservers to query
#
# Params & Result:
#     None
#
#...............................................................................

sub CustomizeResolvFile
{
   my ($self) = @_;

   my @content = ();

   my $dnsSuffices = $self->{_customizationConfig}->GetDNSSuffixes();
   if ($dnsSuffices && @$dnsSuffices) {
      push(@content, "search\t" . join(' ', @$dnsSuffices) . "\n");
   }

   my $dnsNameservers = $self->{_customizationConfig}->GetNameServers();
   if ($dnsNameservers) {
      foreach (@$dnsNameservers) {
         push(@content, "nameserver\t" . $_ . "\n" );
      }
   }

   # Overwrite the resolv.conf file
   Utils::WriteBufferToFile($RESOLVFILE, \@content);
   Utils::SetPermission($RESOLVFILE, $Utils::RWRR);

   if (Utils::IsSelinuxEnabled()) {
      Utils::RestoreFileSecurityContext($RESOLVFILE);
   }
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
#...............................................................................

sub CustomizeDNSFromDHCP
{
   my ($self) = @_;

   # Apply the DNSFromDHCP setting to the dhcp client.
   if ($self->DHClientConfPath() and
      (-e "/sbin/dhclient-script" or -e $self->DHClientConfPath())) {
      my $dnsFromDHCP = $self->{_customizationConfig}->Lookup("DNS|DNSFROMDHCP");
      my $dhclientDomains = $self->{_customizationConfig}->GetDNSSuffixes();

      if ($dnsFromDHCP =~ /no/i) {
            # Overwrite the dhcp answer.

            if (@$dhclientDomains) {
               Utils::AddOrReplaceInFile(
                  $self->DHClientConfPath(),
                  "supersede domain-name ",
                  "supersede domain-name \"".join(" " , @$dhclientDomains)."\";",
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
            "supersede domain-name ",
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
               "append domain-name ",
               "append domain-name \" ".join(" " , @$dhclientDomains)."\";",
               $Utils::SMDONOTSEARCHCOMMENTS);
         }
      }
   }
}

#...............................................................................
#
# GetResolverFQDN
#
# Params:
#   None
#
# Result:
#  Returns the host Fully Quallified Domain Name as returned by the resolver /etc/hosts).
#  It may be different from the one returned by the hostname command. Technically is: Use
#  /etc/hosts etc to resolve what is returned by the hostname command.
#...............................................................................

sub GetResolverFQDN
{
   # Calling 'hostname -f' to let it parse /etc/hosts according the its rules,
   # since there is no better OS API for the moment. Turns out that in case the
   # entry mapping for current IP is missing, it will resort to querying DNS and
   # LDAP which is not time-bound (user can set arbitrary timeouts and numbers
   # of retry) by design. So, we cap it with the max affordable timeout.
   my $fqdn =
      Utils::ExecuteTimedCommand('hostname -f 2>/dev/null', $MAX_CMD_TIMEOUT);
   chomp($fqdn);
   return Utils::Trim($fqdn);
}

# Properties

#...............................................................................
#
# OldHostName
#
# Params:
#   None
#
# Result:
#   Old host name taken from config file.
#...............................................................................

sub OldHostName
{
   die "OldHostName not implemented";
}

#...............................................................................
#
# OldHostName
#
# Params:
#   None
#
# Result:
#   Old host name taken from hostname command.
#...............................................................................

sub OldHostnameCmd
{
   my ($self) = @_;

   return $self->{_oldHostnameCmd};
}

#...............................................................................
#
# OldFQDN
#
# Params:
#   None
#
# Result:
#   Old FQDN from hostname -f command.
#...............................................................................

sub OldFQDN
{
   my ($self) = @_;

   return $self->{_oldResolverFQDN};
}

#...............................................................................
#
# IFCfgFilePrefix
#
#
# Params:
#   None
#
# Result:
#   Returns a prefix (without the interface)  of the path to a interface config file.
#...............................................................................

sub IFCfgFilePrefix
{
   die "IFCfgFilePrefix not implemented";
}

#...............................................................................
#
# DHClientConfPath
#
#
# Params:
#   None
#
# Result:
#   Returns the path to the dynamic hosts config file.
#...............................................................................

sub DHClientConfPath
{
   die "DHClientConfPath not implemented";
}

#...............................................................................
#
# TZPath
#
# Params:
#   None
#
# Result:
#   Returns the path to the time zone info files on the local system.
#...............................................................................

sub TZPath
{
   return "/usr/share/zoneinfo";
}

#...............................................................................
#
# CustomizeDateTime
#  Customizes date and time settings such as time zone, utc, etc.
#
# Params:
#   None
#
# Result:
#   None
#...............................................................................

sub CustomizeDateTime
{
   my ($self) = @_;

   $self->CustomizeTimeZone($self->{_customizationConfig}->GetTimeZone());
   $self->CustomizeUTC($self->{_customizationConfig}->GetUtc());
}

#...............................................................................
#
# CustomizeTimeZone
#  Customizes the time zone
#
# Params:
#   $tzRegionCity - time zone in Region/City format, case sensitive.
#   Examples:
#     Europe/Sofia
#     America/New_York
#     Etc/GMT+2
#
# Result:
#   None
#...............................................................................

sub CustomizeTimeZone
{
   my ($self, $tzRegionCity) = @_;

   if ($tzRegionCity) {
      my $tz = $tzRegionCity;

      if (my %renamedTZInfo = TimezoneDB::GetRenamedTimezoneInfo($tzRegionCity)) {
         # $tzRegionCity has two names - new and old. The old name is linked to
         # the new one. It doesn't matter which we use for the clock but
         # the Linux GUI can show one of them (has a hardcoded list of timezone names)

         if ($self->TimeZoneExists($renamedTZInfo{_currentName})) {
            # Use the new tzname as it is on the guest
            $tz = $renamedTZInfo{_currentName};
         } elsif ($self->TimeZoneExists($renamedTZInfo{_oldName})) {
            # Use the old name as new is not on the guest
            $tz = $renamedTZInfo{_oldName};
         }
      }

      if (not $self->TimeZoneExists($tz)) {
         WARN("Timezone $tz could not be found.");

         my $tzdbPath = TimezoneDB::GetPath();

         if ($tzdbPath) {
            TimezoneDB::Install($self->TZPath());

            if (! $self->TimeZoneExists($tz)) {
               WARN("Timezone $tz could not be installed from $tzdbPath.");

               WARN("Deducing $tz GMT offset.");
               $tz = TimezoneDB::DeduceGMTTimezone($tz);

               if ($tz) {
                  WARN("Timezone $tz will be used.");
                  WARN("Daylight Saving Time will be unavailable.");

                  if (not $self->TimeZoneExists($tz)) {
                     die "Timezone $tz could not be found.";
                  }
               } else {
                  die "Unable to deduce GMT offset";
               }
            }
         } else {
            die "A timezone database could not be found.";
         }
      }

      $self->SetTimeZone($tz);
   }
}

#..............................................................................
#
# GetSystemUTC
#
#  Get the current hardware clock based on the system setting.
#
# Result:
#  UTC or LOCAl.
#
#..............................................................................

sub GetSystemUTC
{
   die "GetSystemUTC not implemented";
}

#...............................................................................
#
# CustomizeUTC
#  Customizes whether the hardware clock is in UTC or in local time.
#
# Params:
#   $utc - "yes" means hardware clock is in utc, "no" means is in local time.
#
# Result:
#   None
#..............................................................................

sub CustomizeUTC
{
   my ($self, $utc) = @_;

   if ($utc) {
      if ($utc =~ /yes|no/) {
         $self->SetUTC($utc);
      } else {
         die "Unknown value for UTC option, value=$utc";
      }
   }
}

#...............................................................................
#
# TimeZoneExists
#  Checks whether timezone information exists on the customized OS.
#
# Params:
#   $tz - timezone in the Region/City format
#
# Result:
#   true or false
#...............................................................................

sub TimeZoneExists
{
   my ($self, $tz) = @_;

   return -e $self->TZPath() . "/$tz";
}

#...............................................................................
#
# SetTimeZone
#  Sets the time zone.
#
# Params:
#   $tz - timezone in the Region/City format
#
# Result:
#   None
#...............................................................................

sub SetTimeZone
{
   die "SetTimeZone not implemented";
}

#...............................................................................
#
# SetUTC
#  Sets whether the hardware clock is in UTC or local time.
#
# Params:
#   $utc - yes or no
#
# Result:
#   None
#...............................................................................

sub SetUTC
{
   die "SetUTC not implemented";
}

#...............................................................................
#
# RestartNetwork
#
#  Restarts the network. Primarily used by hot-customization.
#
#...............................................................................

sub RestartNetwork
{
   die "RestartNetwork is not implemented";
}

#...............................................................................
#
# InstantCloneNicsUp
#
#     Bring up the customized Nics for the instant clone flavor of
#     guest customization.
#
# Params:
#     $self  this object.
#
# Result:
#     Sets _customizationResult to a specific code in case of error.
#
#...............................................................................

sub InstantCloneNicsUp
{
   my ($self) = @_;

   $self->RestartNetwork();
}

#...............................................................................
#
# RenewMachineID
#
#     The /etc/machine-id file contains the unique machine ID of the local
#     system and it should be set during OS installation or boot. But in
#     VM templates which are created once and deployed on multiple VMs,
#     /etc/machine-id should be either missing or an empty file. Then an ID
#     will be generated in the new VMs during OS boot.
#     In case a customer forgets to make /etc/machine-id missing or null in
#     the VM templates, then all the VMs created from this template will have
#     the same machine-id.
#     Especially in instant clone, the parent VM is powered on and its
#     /etc/machine-id won't be cleared because the guest OS is running. So its
#     /etc/machine-id will be copied to the child VMs.
#     To avoid the machind-id duplication issue, renew the machine-id when the
#     customization source is VM clone.
#
# Params:
#     $self  this object.
#
# Result:
#     $MACHINE_ID is renewed, and if $DBUS_MACHINE_ID exists, it will be
#     synced to $MACHINE_ID.
#
#...............................................................................
sub RenewMachineID
{
   my ($self) = @_;

   if (-e $MACHINE_ID) {
      my $machineID = Utils::ExecuteCommand("$Utils::CAT $MACHINE_ID");
      INFO("Old machine ID: $machineID");
      Utils::ExecuteCommand("$Utils::RM $MACHINE_ID");

      INFO("Renewing machine ID ... ");
      Utils::ExecuteCommand("dbus-uuidgen --ensure=/etc/machine-id");

      # When $DBUS_MACHINE_ID exists and it's not a symbolic link to
      # $MACHINE_ID", need to sync $DBUS_MACHINE_ID to $MACHINE_ID by below
      # command.
      if (-e $DBUS_MACHINE_ID && not -l $DBUS_MACHINE_ID) {
         Utils::ExecuteCommand("$Utils::RM $DBUS_MACHINE_ID");
         Utils::ExecuteCommand("dbus-uuidgen --ensure");
      }

      $machineID = Utils::ExecuteCommand("$Utils::CAT $MACHINE_ID");
      INFO("New machine ID: $machineID");
   } else {
      INFO("$MACHINE_ID doesn't exist, skip renewing machine ID");
   }
}

#..............................................................................
#
# SetTransientHostname
#
#     If the hostname file exists, compare the static hostname in the hostname
#     file with the transient hostname obtained from the output of the hostname
#     command. If they do not match, set the transient hostname to the static
#     hostname.
#
#     Params:
#         $self  This object.
#         $hostnameFile The file that records static hostname.
#
#     Result:
#         The transient hostname is the same as the static hostname in the
#         file.
#
#..............................................................................

sub SetTransientHostname
{
   my ($self, $hostnameFile) = @_;

   if (-e $hostnameFile) {
      my $hostnameFromFile = Utils::GetValueFromFile($hostnameFile,
         '^(?!\s*#)([^\s.]+)');
      chomp($hostnameFromFile);
      Utils::Trim($hostnameFromFile);

      my $hostnameFromCmd = Utils::ExecuteCommand('hostname 2>/dev/null');
      chomp($hostnameFromCmd);
      Utils::Trim($hostnameFromCmd);

      if ($hostnameFromCmd ne $hostnameFromFile) {
         Utils::ExecuteCommand("hostname $hostnameFromFile");

         my $hostname = Utils::ExecuteCommand('hostname 2>/dev/null');
         INFO("After reset, the hostname is $hostname");
      }
   } else {
      WARN("Hostname file '$hostnameFile' not found.");
   }
}

1;
