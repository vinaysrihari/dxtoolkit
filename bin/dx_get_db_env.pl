# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Copyright (c) 2014,2016 by Delphix. All rights reserved.
#
# Program Name : dx_get_db_env.pl
# Description  : Get database and host information
# Author       : Edward de los Santos
# Created: 30 Jan 2014 (v1.0.0)
#
# Modified: 03 Mar 2015 (v1.0.2) Marcin Przepiorowski
#
# Modified: 14 Mar 2015 (v2.0.0) Marcin Przepiorowski


use strict;
use warnings;
use JSON;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev); #avoids conflicts with ex host and help
use File::Basename;
use Pod::Usage;
use FindBin;
use Data::Dumper;
use File::Spec;

my $abspath = $FindBin::Bin;

use lib '../lib';
use Databases;
use Engine;
use Timeflow_obj;
use Capacity_obj;
use Formater;
use Group_obj;
use Toolkit_helpers;
use Snapshot_obj;
use Hook_obj;

my $version = $Toolkit_helpers::version;

my $parentlast = 'p';
my $hostenv = 'h';

GetOptions(
  'help|?' => \(my $help),
  'd|engine=s' => \(my $dx_host),
  'name=s' => \(my $dbname),
  'format=s' => \(my $format),
  'type=s' => \(my $type),
  'group=s' => \(my $group),
  'host=s' => \(my $host),
  'dsource=s' => \(my $dsource),
  'primary' => \(my $primary),
  'envname=s' => \(my $envname),
  'instance=n' => \(my $instance),
  'debug:i' => \(my $debug),
  'parentlast=s' =>  \($parentlast),
  'hostenv=s' =>  \($hostenv),
  'config' => \(my $config),
  'backup=s' => \(my $backup),
  'save=s' => \(my $save),
  'dever=s' => \(my $dever),
  'all' => (\my $all),
  'version' => \(my $print_version),
  'nohead' => \(my $nohead)
) or pod2usage(-verbose => 1,  -input=>\*DATA);

pod2usage(-verbose => 2,  -input=>\*DATA) && exit if $help;
die  "$version\n" if $print_version;

my $engine_obj = new Engine ($dever, $debug);
my $path = $FindBin::Bin;
my $config_file = $path . '/dxtools.conf';

$engine_obj->load_config($config_file);


if (defined($all) && defined($dx_host)) {
  print "Option all (-all) and engine (-d|engine) are mutually exclusive \n";
  pod2usage(-verbose => 1,  -input=>\*DATA);
  exit (1);
}

Toolkit_helpers::check_filer_options (undef, $type, $group, $host, $dbname, $envname);

# this array will have all engines to go through (if -d is specified it will be only one engine)
my $engine_list = Toolkit_helpers::get_engine_list($all, $dx_host, $engine_obj);

my $output = new Formater();
my $dsource_output;

my $parentlast_head;
my $hostenv_head;

if (lc $parentlast eq 'p') {
  $parentlast_head = 'Parent snapshot';
} elsif (lc $parentlast eq 'l') {
  $parentlast_head = 'Last snapshot';
} else {
  print "Option parentlast has a wrong argument\n";
  pod2usage(-verbose => 1,  -input=>\*DATA);
  exit (1);
}

if (lc $hostenv eq 'h') {
  $hostenv_head = 'Hostname';
} elsif (lc $hostenv eq 'e') {
  $hostenv_head = 'Env. name';
} else {
  print "Option hostenv has a wrong argument\n";
  pod2usage(-verbose => 1,  -input=>\*DATA);
  exit (1);
}

if (defined($backup)) {
  if (! -d $backup) {
    print "Path $backup is not a directory \n";
    exit (1);  
  }
  if (! -w $backup) {
    print "Path $backup is not writtable \n";
    exit (1);  
  }
  
  $hostenv = 'e';
  $output->addHeader(
      {'Paramters', 200}
  );
  
  $dsource_output = new Formater();
  $dsource_output->addHeader(
      {'Paramters', 200}
  );
  
} elsif (defined($config)) {
  $hostenv = 'e';
  $output->addHeader(
    {'Appliance', 10},
    {'Env. name', 20},
    {'Database',   30},
    {'Group',      15},
    {'Type',        8},
    {'SourceDB',   30},
    {'Repository', 35},
    {'DB type',    10},
    {'Version',    10},
    {'Other',      30}
  );
} else {
  $output->addHeader(
    {'Appliance', 10},
    {$hostenv_head,  20},
    {'Database',  30},
    {'Group',     15},
    {'Type',       8},
    {'SourceDB',  30},
    {$parentlast_head, 35},
    {'Used(GB)',  10},
    {'Status',    10},
    {'Enabled',   10},
  );
}



my %save_state;

my $ret = 0;

for my $engine ( sort (@{$engine_list}) ) {
  # main loop for all work
  if ($engine_obj->dlpx_connect($engine)) {
    print "Can't connect to Dephix Engine $engine\n\n";
    next;
  };

  # load objects for current engine
  my $databases = new Databases( $engine_obj, $debug);
  my $capacity;
  my $timeflows;
  my $groups = new Group_obj($engine_obj, $debug);
  my $templates;
  my $snapshots;
  if (defined($backup)) {
      $templates = new Template_obj($engine_obj, $debug);
  } else {
    if (lc $parentlast eq 'p') {
      $snapshots = new Snapshot_obj($engine_obj, undef, undef, $debug);
    } 
    $capacity = new Capacity_obj($engine_obj, $debug); 
    $timeflows = new Timeflow_obj($engine_obj, $debug);  
  }

  # filter implementation

  my $db_list = Toolkit_helpers::get_dblist_from_filter($type, $group, $host, $dbname, $databases, $groups, $envname, $dsource, $primary, $instance, $debug);
  if (! defined($db_list)) {
    print "There is no DB selected to process on $engine . Please check filter definitions. \n";
    $ret = $ret + 1;
    next;
  }




  # for filtered databases on current engine - display status
  for my $dbitem ( @{$db_list} ) {
    my $dbobj = $databases->getDB($dbitem);

    my $parentsnap;
    my $snaptime;
    my $hostenv_line;
    my $timezone;
    my $parentname;
    my $parentgroup;

    if ( $dbobj->getParentContainer() ne '' ) {
      $parentname = $databases->getDB($dbobj->getParentContainer())->getName();
      my $parentgroup_ref = $databases->getDB($dbobj->getParentContainer())->getGroup();
      $parentgroup = $groups->getName($parentgroup_ref);
    } else {
      $parentname = '';
    }

    if (lc $hostenv eq 'h') {
      $hostenv_line = $dbobj->getHost();
    } else {
      $hostenv_line = $dbobj->getEnvironmentName();
    }


    if (defined($config)) {

      my $other = '';
      if ($dbobj->{_dbtype} eq 'oracle') {
        $other = $other . $dbobj->getArchivelog();
      }
      if ( ( $dbobj->getType() eq 'dSource')  && ( $dbobj->{_dbtype} ne 'oracle' ) && ( $dbobj->{_dbtype} ne  'vFiles' ) ) {
        $other = $other . $dbobj->getStagingEnvironment() . "," . $dbobj->getStagingInst();
      }
      $output->addLine(
        $engine,
        $hostenv_line,
        $dbobj->getName(),
        $groups->getName($dbobj->getGroup()),
        $dbobj->getType(),
        $parentname,
        $dbobj->getHome(),
        $dbobj->{_dbtype},
        $dbobj->getVersion(),
        $other
      );
    } elsif (defined($backup)) {
      
      my $suffix = '';
      if ( $^O eq 'MSWin32' ) { 
        $suffix = '.exe';
      }
      
      my $dbtype = $dbobj->getType();
      my $groupname = $groups->getName($dbobj->getGroup());
      my $dbn = $dbobj->getName();
      my $dbhostname;
      my $vendor = $dbobj->{_dbtype};
      my $rephome = $dbobj->getHome();

      my $hooks = new Hook_obj (  $engine_obj, 1, $debug );
      
      $hooks->exportDBHooks($dbobj, $backup);
      
      my $restore_args;
      
      if ($dbtype eq 'VDB') {
        # VDB
        
        $dbhostname = $dbobj->getDatabaseName();
        if (($parentname eq '') && ($vendor eq 'vFiles')) {
          $restore_args = "dx_provision_vdb$suffix -d $engine -type $vendor -group \"$groupname\" -creategroup -empty -targetname \"$dbn\" -dbname \"$dbhostname\" -environment \"$hostenv_line\" -envinst \"$rephome\" ";
        } else {
          $restore_args = "dx_provision_vdb$suffix -d $engine -type $vendor -group \"$groupname\" -creategroup -sourcename \"$parentname\"  -srcgroup \"$parentgroup\" -targetname \"$dbn\" -dbname \"$dbhostname\" -environment \"$hostenv_line\" -envinst \"$rephome\" ";          
        }
        
        $restore_args = $restore_args . " -envUser \"" . $dbobj->getEnvironmentUserName() . "\" ";
        $restore_args = $restore_args . " -hooks " . File::Spec->catfile($backup,$dbn.'.dbhooks') . " ";
        
        if ($vendor eq 'oracle') {
          my $mntpoint = $dbobj->getMountPoint();
          my $archlog = $dbobj->getArchivelog();
          my $tempref = $dbobj->getTemplateRef();
          my $listnames = $dbobj->getListenersNames();
          my $redogroups = $dbobj->getRedoGroupNumber();
          
          if ($redogroups ne 'N/A') {
            $restore_args = $restore_args . " -redoGroup $redogroups ";
            my $redosize = $dbobj->getRedoGroupSize();
            if (($redosize ne 'N/A') && ($redosize ne 0)) {
              $restore_args = $restore_args . " -redoSize $redosize ";
            }
            
          }
                    
          if (defined($tempref)) {
            my $tempname = $templates->getTemplate($tempref)->{name};
            $restore_args = $restore_args . " -template $tempname";
          }
          $restore_args = $restore_args . " -mntpoint \"$mntpoint\" -$archlog " ;
          if (defined($listnames) && ($listnames ne '')) {
            $restore_args = $restore_args . " -listeners $listnames ";
          }
          
          #if one instance use -instanceName
          my $instances = $dbobj->getInstances();
                              
          if ($dbobj->isRAC()) {
            #rac 
            my $rac = '';
            for my $inst (@{$instances}) {
              $rac = $rac . "-rac_instance " . $dbobj->getInstanceNode($inst->{instanceNumber}) . "," . $inst->{instanceName} . "," . $inst->{instanceNumber} . " "; 
            }
            $restore_args = $restore_args . " " . $rac;
          } else {
            $restore_args = $restore_args . " -instname " . $instances->[-1]->{instanceName} . " ";
          }
          
          my $unique = $dbobj->getUniqueName();
          if ($unique ne 'N/A') {
            $restore_args = $restore_args . " -uniqname $unique ";
          }
          
          
        }
        
        if ($vendor eq "mssql") {
          my $recoveryModel = $dbobj->getRecoveryModel();       
          $restore_args = $restore_args . " -recoveryModel $recoveryModel";
        }
        
        if ($vendor eq 'vFiles') {
          my $addmount = $dbobj->getAdditionalMountpoints();
          for my $am (@{$addmount}) {
            $restore_args = $restore_args . " -additionalMount $am ";
          }
        }
        
        $output->addLine(
          $restore_args
        );
        
      } else {
        # dSource export
        #my $users = new 
        $dbhostname = $dbobj->getSourceName() ? $dbobj->getSourceName() : 'detached';
        my $osuser = $dbobj->getOSUser();
                
        $restore_args = "dx_ctl_dsource$suffix -d $engine -action create -group \"$groupname\" -creategroup -dsourcename \"$dbn\"  -type $vendor -sourcename \"$dbhostname\" -sourceinst \"$rephome\" -sourceenv \"$hostenv_line\" -source_os_user \"$osuser\" ";
        
        if ($vendor ne 'vFiles') {
          my $logsync = $dbobj->getLogSync() eq 'ACTIVE'? 'yes' : 'no' ;
          my $dbuser = $dbobj->getDbUser();
          
          # if ($dbhostname eq 'detached') {
          #   $dbuser = 'N/A';
          # }
          $restore_args = $restore_args . "-dbuser $dbuser -password ChangeMeDB -logsync $logsync";
        }
        
          
        if (($vendor eq "mssql") || ($vendor eq "sybase")) {
          my $staging_user = $dbobj->getStagingUser();
          my $staging_env = $dbobj->getStagingEnvironment();
          my $staging_inst = $dbobj->getStagingInst();
                    
          $restore_args = $restore_args . " -stageinst \"$staging_inst\" -stageenv \"$staging_env\" -stage_os_user \"$staging_user\" ";
        }
        
        if ($vendor eq "mssql") {
          my $backup_path = $dbobj->getBackupPath();
          if (!defined($backup_path)) {
            #autobackup path
            $backup_path = "";
          }
          if (defined($backup_path)) {
            $backup_path =~ s/\\/\\\\/g;
          }
          my $vsm = $dbobj->getValidatedMode();
          my $dmb = $dbobj->getDelphixManaged();
        
          if ($dmb eq 'yes') {
            $restore_args = $restore_args . " -delphixmanaged $dmb ";
          } else {
            $restore_args = $restore_args . " -validatedsync $vsm -backup_dir \"$backup_path\" ";
          }
        }
        
        if ($vendor eq "sybase") {
          my $backup_path = $dbobj->getBackupPath();
          $restore_args = $restore_args . " -backup_dir \"$backup_path\" ";
        }
        
        $dsource_output->addLine(
          $restore_args
        );
        
      }

    } else {

      $parentsnap = $timeflows->getParentSnapshot($dbobj->getCurrentTimeflow());

      if (lc $parentlast eq 'p') {
        if (($parentsnap ne '') && ($dbobj->getType() eq 'VDB')) {
          ($snaptime,$timezone) = $snapshots->getSnapshotTimewithzone($parentsnap);
        } else {
          $snaptime = 'N/A';
        }
      }

      if (lc $parentlast eq 'l') {
        my $dsource_snaps = new Snapshot_obj($engine_obj,$dbobj->getReference(), undef, $debug);
        ($snaptime,$timezone) = $dsource_snaps->getLatestSnapshotTime();
      }

      $output->addLine(
        $engine,
        $hostenv_line,
        $dbobj->getName(),
        $groups->getName($dbobj->getGroup()),
        $dbobj->getType(),
        $parentname,
        #$timeflows->getParentSnapshot($dbobj->getCurrentTimeflow()),
        $snaptime,
        $capacity->getDatabaseUsage($dbobj->getReference()),
        $dbobj->getRuntimeStatus(),
        $dbobj->getEnabled()
      );

    }

    $save_state{$dbobj->getName()}{$dbobj->getHost()} = $dbobj->getEnabled();

  }

  if ( defined($save) ) {
    # save file format - userspecified.enginename
    my $save_file = $save . "." . $engine;
    open (my $save_stream, ">", $save_file) or die ("Can't open file $save_file for writting : $!" );
    print $save_stream to_json(\%save_state, {pretty => 1});
    close $save_stream;
  }

}

if (defined($backup)) {
    
  my $FD;
  my $filename = File::Spec->catfile($backup,'backup_metadata_dsource.txt');
  
  if ( open($FD,'>', $filename) ) {
    $dsource_output->savecsv(1,$FD);
    print "Backup exported into $filename \n";
  } else {
    print "Can't create a backup file $filename \n";
    $ret = $ret + 1;
  }
  close ($FD);

  $filename = File::Spec->catfile($backup,'backup_metadata_vdb.txt');
  
  if ( open($FD,'>', $filename) ) {
    $output->savecsv(1,$FD);
    print "Backup exported into $filename \n";
  } else {
    print "Can't create a backup file $filename \n";
    $ret = $ret + 1;
  }
  close ($FD);
  
} else {
    Toolkit_helpers::print_output($output, $format, $nohead);  
}


exit $ret;

__DATA__

=head1 SYNOPSIS

 dx_get_db_env.pl [-engine|d <delphix identifier> | -all ] 
                  [-group group_name | -name db_name | -host host_name | -type dsource|vdb ] 
                  [-save]
                  [-parentlast l|p] 
                  [-config]
                  [-backup path] 
                  [-hostenv h|e] 
                  [-format csv|json ] 
                  [-help|? ] [ -debug ]

=head1 DESCRIPTION

Get the information about databases.

=head1 ARGUMENTS

Delphix Engine selection - if not specified a default host(s) from dxtools.conf will be used.

=over 10

=item B<-engine|d>
Specify Delphix Engine name from dxtools.conf file

=item B<-all>
Display databases on all Delphix appliance

=back

=head2 Filters

Filter databases using one of the following filters

=over 4

=item B<-group>
Group Name

=item B<-name>
Database Name

=item B<-host>
Host Name

=item B<-type>
Type (dsource|vdb)

=item B<-envname>
Environment name

=item B<-dsource dsourcename>
Dsource name

=back

=head3 Instance option

Specify a instance number (only with combination with host)

=over 4

=item B<-instance inst_no>
Instance number

=back

=head1 OPTIONS

=over 3

=item B<-config>
Display a config of databases (db type, version, instance / Oracle home) plus others

=item B<-backup path>
Gnerate a dxToolkit commands to recreate databases ( Oracle / MS SQL support )
into path

=item B<-parentlast l|p>
Change a snapshot column to display :
l - a last snapshot time (default)
p - parent snapshot for VDB

=item B<-hostenv h|e>
Change a hostname/env column to display :
h - target host name (default)
e - target environment name


=item B<-format>
Display output in csv or json format
If not specified pretty formatting is used.

=item B<-help>
Print this screen

=item B<-debug>
Turn on debugging

=item B<-save <filename> >
Save enabled column into JSON file <filename.engine_name> to restore it later using dx_ctl_db.pl

=item B<-nohead>
Turn off header output

=back




=cut
