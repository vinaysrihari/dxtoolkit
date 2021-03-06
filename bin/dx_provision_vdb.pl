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
# Copyright (c) 2015,2016 by Delphix. All rights reserved.
#
# Program Name : dx_provision_vdb.pl
# Description  : Provision a VDB
#
# Author       : Marcin Przepiorowski
# Created      : 13 Apr 2015 (v2.0.0)
#



use strict;
use warnings;
use JSON;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev); #avoids conflicts with ex host and help
use File::Basename;
use Pod::Usage;
use FindBin;
use Data::Dumper;
use Try::Tiny;

my $abspath = $FindBin::Bin;

use lib '../lib';
use Databases;
use Engine;
use Jobs_obj;
use Group_obj;
use Toolkit_helpers;
use FileMap;

my $version = $Toolkit_helpers::version;

my $archivelog = 'yes';

GetOptions(
  'help|?' => \(my $help), 
  'd|engine=s' => \(my $dx_host), 
  'sourcename=s' => \(my $sourcename), 
  'empty' => \(my $empty), 
  'targetname=s' => \(my $targetname), 
  'dbname|path=s'  => \(my $dbname), 
  'instname=s'  => \(my $instname), 
  'uniqname=s'  => \(my $uniqname), 
  'environment=s' => \(my $environment), 
  'envUser=s' => \(my $envUser), 
  'type=s' => \(my $type), 
  'group=s' => \(my $group), 
  'creategroup' => \(my $creategroup),
  'listeners=s'  => \(my $listeners),
  'srcgroup=s' => \(my $srcgroup), 
  'envinst=s' => \(my $envinst),
  'template=s' => \(my $template),
  'mapfile=s' =>\(my $map_file),
  'port=n' =>\(my $port),
  'postrefresh=s' =>\(my $postrefresh),
  'rac_instance=s@' => \(my $rac_instance),
  'additionalMount=s@' => \(my $additionalMount),
  'configureclone=s' => \(my $configureclone),
  'prerefresh=s' =>\(my $prerefresh),
  'prerewind=s' =>\(my $prerewind), 
  'postrewind=s' =>\(my $postrewind), 
  'presnapshot=s' =>\(my $presnapshot), 
  'postsnapshot=s' =>\(my $postsnapshot),
  'hooks=s' => \(my $hooks),
  'prescript=s' => \(my $prescript),
  'postscript=s' => \(my $postscript),  
  'timestamp=s' => \(my $timestamp),
  'location=s' => \(my $changenum),
  'mntpoint=s' => \(my $mntpoint),
  'redoGroup=s' => \(my $redoGroup),
  'redoSize=s' => \(my $redoSize),
  'archivelog=s' => \($archivelog),
  'truncateLogOnCheckpoint' => \(my $truncateLogOnCheckpoint),
  'recoveryModel=s' => \(my $recoveryModel),
  'noopen' => \(my $noopen),
  'dever=s' => \(my $dever),
  'debug:n' => \(my $debug), 
  'all' => (\my $all),
  'version' => \(my $print_version)
) or pod2usage(-verbose => 1, -input=>\*DATA);



pod2usage(-verbose => 1, -input=>\*DATA) && exit if $help;
die  "$version\n" if $print_version;   


my $engine_obj = new Engine ($dever, $debug);
my $path = $FindBin::Bin;
my $config_file = $path . '/dxtools.conf';

$engine_obj->load_config($config_file);


if (defined($all) && defined($dx_host)) {
  print "Option all (-all) and engine (-d|engine) are mutually exclusive \n";
  pod2usage(-verbose => 1, -input=>\*DATA);
  exit (1);
}

if (( $type eq 'vFiles' ) && (!defined($envinst)) ) {
  $envinst = 'Unstructured Files';
}



if ( ! ( defined($type) && defined($targetname) && defined($dbname) && defined($environment) && defined($group) && defined($envinst)  ) ) {
  print "Options -type, -targetname, -dbname, -environment, -group and -envinst are required. \n";
  pod2usage(-verbose => 1, -input=>\*DATA);
  exit (1);
}

if (! ( defined($sourcename) || defined($empty) ) ) {
  print "Options -sourcename or -empty are required. \n";
  pod2usage(-verbose => 1, -input=>\*DATA);
  exit (1);  
}


if ( defined($archivelog) && (! ( ( $archivelog eq 'yes') || ( $archivelog eq 'no') ) ) )   {
  print "Option -archivelog has invalid parameter - $archivelog \n";
  pod2usage(-verbose => 1, -input=>\*DATA);
  exit (1);
}


if ( ! ( ( $type eq 'oracle') || ( $type eq 'mssql') || ( $type eq 'sybase') || ( $type eq 'mysql') || ( $type eq 'vFiles') ) )  {
  print "Option -type has invalid parameter - $type \n";
  pod2usage(-verbose => 1, -input=>\*DATA);
  exit (1);
}

if (defined($timestamp) && defined($changenum)) {
  print "Parameter timestamp and location are mutually exclusive \n";
  pod2usage(-verbose => 1, -input=>\*DATA);
  exit (1);
}

if (! defined($timestamp) && (! defined ($changenum) ) ) {
  $timestamp = 'LATEST_SNAPSHOT';
}


# this array will have all engines to go through (if -d is specified it will be only one engine)
my $engine_list = Toolkit_helpers::get_engine_list($all, $dx_host, $engine_obj); 

my $ret = 0;

for my $engine ( sort (@{$engine_list}) ) {
  # main loop for all work
  if ($engine_obj->dlpx_connect($engine)) {
    print "Can't connect to Dephix Engine $dx_host\n\n";
    next;
  };

  my $db;
  my $jobno;


  my $databases = new Databases($engine_obj,$debug);
  my $groups = new Group_obj($engine_obj, $debug); 

  if (! defined($groups->getGroupByName($group))) {
    if (defined($creategroup)) {
      print "Creating not existing group - $group \n";
      my $jobno = $groups->createGroup($group);
      my $actionret = Toolkit_helpers::waitForAction($engine_obj, $jobno, "Action completed with success", "There were problems with group creation");
      if ($actionret > 0) {
        $ret = $ret + 1;
        print "There was a problem with group creation. Skipping source actions on engine\n";
        next;
      }
    } else {
      print "Group $group for target database doesn't exist.\n Skipping source actions on engine.\n";
      $ret = $ret + 1;
      next;
    }
  } 
  
  my $source;
  
  if (defined($sourcename)) {
    my $source_ref = Toolkit_helpers::get_dblist_from_filter(undef, $srcgroup, undef, $sourcename, $databases, $groups, undef, undef, undef, undef, $debug);

    if (!defined($source_ref)) {
      print "Source database not found.\n";
      $ret = $ret + 1;
      next;
    }

    if (scalar(@{$source_ref})>1) {
      print "Source database not unique defined.\n";
      $ret = $ret + 1;
      next;
    } elsif (scalar(@{$source_ref}) eq 0) {
      print "Source database not found.\n";
      $ret = $ret + 1;
      next;
    }

    $source = ($databases->getDB($source_ref->[0]));
  }
  
  # create a new DB object
  if ( $type eq 'oracle' ) {
    $db = new OracleVDB_obj($engine_obj,$debug);
  } elsif ($type eq 'mssql') {
      $db = new MSSQLVDB_obj($engine_obj,$debug);
  } elsif ($type eq 'sybase') {
    $db = new SybaseVDB_obj($engine_obj,$debug);
  } elsif ($type eq 'mysql') {
    $db = new MySQLVDB_obj($engine_obj,$debug);
  } elsif ($type eq 'vFiles') {
    $db = new AppDataVDB_obj($engine_obj,$debug);
  }
  
  # common database code
  
  if (defined($source)) {
    if ( $db->setSource($source) ) {
      print "Problem with setting source $source . VDB won't be created.\n";
      $ret = $ret + 1;
      next;
    }
    if ( defined ($timestamp) ) {
      if ( $db->setTimestamp($timestamp) ) {
        print "Problem with setting timestamp $timestamp. VDB won't be created.\n";
        $ret = $ret + 1;
        next;
      }
    } elsif ( defined ($changenum) ) {
        if ($db->setChangeNum($changenum)) {
            print "Error with location format.  VDB won't be created.\n";
            $ret = $ret + 1;
            next;
        }
    }
    
  } elsif (($type eq 'vFiles') && (defined($empty))) {
    $db->setEmpty();
  } else {
    print "There is no source configured\n";
    $ret = $ret + 1;
    last;
  }


  
  if ( $db->setEnvironment($environment,$envUser) ) {
      print "Environment $environment or user user not found. VDB won't be created\n";
      $ret = $ret + 1;
      next; 
  }
  
  if ( defined($postrefresh) ) {
    my $oneline = Toolkit_helpers::readHook('postrefresh', $postrefresh);
    if (defined($oneline)) {
      $db->setPostRefreshHook($oneline);
    } else {
      $ret = $ret + 1;
      last;
    }    
  } 

  if ( defined($configureclone) ) {
    my $oneline = Toolkit_helpers::readHook('configureclone', $configureclone);
    if (defined($oneline)) {
      $db->setconfigureCloneHook($oneline);
    } else {
      $ret = $ret + 1;
      last;
    }   
  } 

  if ( defined($prerefresh) ) {
    my $oneline = Toolkit_helpers::readHook('prerefresh', $prerefresh);
    if (defined($oneline)) {
      $db->setPreRefreshHook($oneline);
    } else {
      $ret = $ret + 1;
      last;
    }   
  } 
  
  if ( defined($prerewind) ) {
    my $oneline = Toolkit_helpers::readHook('prerewind', $prerewind);
    if (defined($oneline)) {
      $db->setPreRewindHook($oneline);
    } else {
      $ret = $ret + 1;
      last;
    }   
  } 

  if ( defined($postrewind) ) {
    my $oneline = Toolkit_helpers::readHook('postrewind', $postrewind);
    if (defined($oneline)) {
      $db->setPostRewindHook($oneline);
    } else {
      $ret = $ret + 1;
      last;
    }   
  } 
  
  if ( defined($presnapshot) ) {
    my $oneline = Toolkit_helpers::readHook('presnapshot', $presnapshot);
    if (defined($oneline)) {
      $db->setPreSnapshotHook($oneline);
    } else {
      $ret = $ret + 1;
      last;
    }   
  } 
  
  if ( defined($postsnapshot) ) {
    my $oneline = Toolkit_helpers::readHook('postsnapshot', $postsnapshot);
    if (defined($oneline)) {
      $db->setPostSnapshotHook($oneline);
    } else {
      $ret = $ret + 1;
      last;
    }   
  } 
  
  if (defined($hooks)) {
    my $FD;
    if (!open ($FD, '<', "$hooks")) {
      print "Can't open a file with hooks: $hooks\n";
      $ret = $ret + 1;
      last;
    } 
    local $/ = undef;
    my $json = JSON->new();
    my $loadedHooks;
    
    try {
       $loadedHooks = $json->decode(<$FD>);
    } catch {
       print 'Error parsing hooks file. Please check it. ' . $_ . " \n" ;
       close $FD;
       $ret = $ret + 1;
       last;
    };
    close $FD;
    
    if ($loadedHooks->{type} ne 'VirtualSourceOperations') {
      print '$hooks is not a export file from dx_get_hooks\n' ;
      $ret = $ret + 1;
      last;
    }
        
    $db->setHooksfromJSON($loadedHooks);  
    
    
  }

  # Database specific code
  if ( $type eq 'oracle' ) {  
    if (length($dbname) > 8) {
      print "Max. size of dbname for Oracle is 8 characters\n.";
      print "VDB won't be created\n";
      $ret = $ret + 1;
      last;
    }

    if (defined($instname) && (length($instname) > 12)) {
      print "Max. size of instance name for Oracle is 12 characters\n.";
      print "VDB won't be created\n";
      $ret = $ret + 1;
      last;
    }

    if ( defined($map_file) ) {
      my $filemap_obj = new FileMap($engine_obj,$debug);
      $filemap_obj->loadMapFile($map_file);
      $filemap_obj->setSource($source);
      if ($filemap_obj->validate()) {
        die ("Problem with mapping file. VDB won't be created.")
      }

      $db->setMapFile($filemap_obj->GetMapping_rule());

    }
    
    if (defined($redoSize)) {
      $db->setRedoGroupSize($redoSize);
    }

    if (defined($redoGroup)) {
      $db->setRedoGroupNumber($redoGroup);
    }

    if (defined($archivelog)) {
      $db->setArchivelog($archivelog);
    }

    if (defined($mntpoint)) {
      $db->setMountPoint($mntpoint);
    }

    if (defined($noopen)) {
      $db->setNoOpen();
    }

    if ( defined($template) ) {
      if ( $db->setTemplate($template) ) {
        print "Template $template not found. VDB won't be created\n" ;
        $ret = $ret + 1;
        next;
      }  
    } else {    
     if ( $db->setDefaultParams() ) {
        print "Problem with setting default parameters . VDB won't be created.\n";
        $ret = $ret + 1;
        next;
      }
    }

    $db->setName($targetname,$dbname, $uniqname, $instname);
    
    if (defined($listeners)) {    
      if ( $db->setListener($listeners) ) {
        print "Listener not found. VDB won't be created\n";
        $ret = $ret + 1;
        next; 
      }
    }
        
    $jobno = $db->createVDB($group,$environment,$envinst,$rac_instance);
  } 
  elsif ($type eq 'mssql') {

    if ( defined($postscript) ) {
      $db->setPostScript($postscript)
    } 

    if ( defined($prescript) ) {
      $db->setPreScript($prescript)
    } 

    if ( defined($recoveryModel) ) {
      if ($db->setRecoveryModel($recoveryModel)) {
        print "Problem with setting Recovery Model $recoveryModel. VDB won't be created.\n";
        $ret = $ret + 1;
        next; 
      };
    }

    $db->setName($targetname, $dbname);
    $jobno = $db->createVDB($group,$environment,$envinst);
    
  } elsif ($type eq 'sybase') {
     
    $db->setName($targetname, $dbname);
    $db->setLogTruncate($truncateLogOnCheckpoint);
    $jobno = $db->createVDB($group,$environment,$envinst);
  } elsif ($type eq 'mysql') {

    if (! defined($port)) {
        print "Port not defined. VDB won't be created.\n";
        $ret = $ret + 1;
        next; 
    }

    $db->setName($targetname, $dbname);
    $jobno = $db->createVDB($group,$environment,$envinst,$port, $mntpoint);
  } elsif ($type eq 'vFiles') {
    if (defined($additionalMount)) {
      if ($db->setAdditionalMountpoints($additionalMount)) {
        print "Problem with additional mount points. VDB won't be created.\n";
        $ret = $ret + 1;
        next;   
      }
    }
    $db->setName($targetname, $dbname);
    $jobno = $db->createVDB($group,$environment,$envinst);
  } 


  $ret = $ret + Toolkit_helpers::waitForJob($engine_obj, $jobno, "VDB created.","Problem with VDB creation");

}

exit $ret;

__DATA__


=head1 SYNOPSIS

 dx_provision_vdb.pl [ -engine|d <delphix identifier> | -all ]  
 -group group_name 
 -sourcename src_name 
 -targetname targ_name 
 -dbname db_name | -path vfiles_mountpoint 
 -environment environment_name 
 -type oracle|mssql|sybase|vFiles 
 -envinst OracleHome/MSSQLinstance/SybaseServer
 [-creategroup]
 [-srcgroup Source group]
 [-timestamp LATEST_SNAPSHOT|LATEST_POINT|time_stamp]
 [-template template_name] 
 [-mapfile mapping_file]  
 [-instname SID] 
 [-uniqname db_unique_name] 
 [-mntpoint mount_point ]
 [-noopen]
 [-truncateLogOnCheckpoint]
 [-archivelog yes/no]
 [-postrefresh pathtoscript ]
 [-configureclone pathtoscript ]
 [-prerefresh  pathtoscript ]  
 [-prescript pathtoscript ]
 [-postscript pathtoscript ]
 [-recoveryModel model ]
 [-additionalMount envname,mountpoint,sharedpath]
 [-rac_instance env_node,instance_name,instance_no ]
 [-redoGroup N]
 [-redoSize N]
 [-listeners listener_name]
 [-hooks path_to_hooks]
 [-envUser username]
 [-help] [-debug]


=head1 DESCRIPTION

Provision VDB from a defined source on the defined target environment.

=head1 ARGUMENTS

=head2 Delphix Engine selection - if not specified a default host(s) from dxtools.conf will be used.

=over 10

=item B<-engine|d>
Specify Delphix Engine name from dxtools.conf file

=item B<-all>
Display databases on all Delphix appliance

=back

=head2 VDB arguments

=over 1

=item B<-type type>
Type (oracle|mssql|sybase|vFiles)

=item B<-group name>
Group Name

=item B<-creategroup>
Specify this option to create a new group on Delphix Engine 
while proviioning a new VDB

=item B<-sourcename name>
dSource Name

=item B<-targetname name>
Target name

=item B<-dbname name>
Target database name

=item B<-path path>
Mount point location for vFiles

=item B<-srcgroup Source group>
Group name where source is located

=item B<-timestamp timestamp>
Time stamp formats: 

YYYY-MM-DD HH24:MI:SS or LATEST_POINT for point in time, 

@YYYY-MM-DDTHH24:MI:SS.ZZZ , YYYY-MM-DD HH24:MI or LATEST_SNAPSHOT for snapshots.
@YYYY-MM-DDTHH24:MI:SS.ZZZ is a snapshot name from dx_get_snapshot, while YYYY-MM-DD HH24:MI is a 
snapshot time in GUI format


Default is LATEST_SNAPSHOT


=item B<-location location>
Point in time defined by SCN for Oracle and LSN for MS SQL 

=item B<-environment environment_name>
Target environment name

=item B<-envinst environment_instance>
Target environment Oracle Home, MS SQL server instance, Sybase server name, etc

=item B<-template template_name>
Target VDB template name (for Oracle)

=item B<-mapfile filename>
Target VDB mapping file (for Oracle)

=item B<-instname instance_name>
Target VDB instance name (for Oracle)

=item B<-uniqname db_unique_name>
Target VDB db_unique_name (for Oracle)

=item B<-mntpoint path>
Set a mount point for VDB (for Oracle)

=item B<-noopen>
Don't open database after provision (for Oracle)

=item B<-archivelog yes/no>
Create VDB in archivelog (yes - default) or noarchielog (no) (for Oracle)

=item B<-truncateLogOnCheckpoint>
Truncate a log on checkpoint. Set this parameter to enable truncate operation (for Sybase)

=item B<-postrefresh pathtoscript>
Post refresh hook

=item B<-configureclone pathtoscript>
Configure Clone hook

=item B<-prerefresh pathtoscript>
Prerefresh hook

=item B<-prescript  pathtoscript>
Path to prescript on Windows target

=item B<-postscript  pathtoscript>
Path to postscript on Windows target

=item B<-recoveryModel model>
Set a recovery model for MS SQL database. Allowed values
BULK_LOGGED,FULL,SIMPLE

=item B<-additionalMount envname,mountpoint,sharedpath>
Set an additinal mount point for vFiles - using a syntax
environment_name,mount_point,sharedpath

ex. -additionalMount target1,/u01/app/add,/


=item B<-rac_instance env_node,instance_name,instance_no>
Comma separated information about node name, instance name and instance number for a RAC provisioning
Repeat option if you want to provide information for more nodes

ex. -rac_instance node1,VBD1,1 -rac_instance node2,VBD2,2 


=item B<-redoGroup N>
Create N redo groups

=item B<-redoSize N>
Each group will be N MB in size

=item B<-listeners listener_name>
Use listener named listener_name

=item B<-hooks path_to_hooks>
Import hooks exported using dx_get_hooks 

=item B<-envUser username>
Use an environment user "username" for provisioning database

=back


=head1 OPTIONS

=over 2

=item B<-help>          
Print usage information

=item B<-debug>
Turn on debugging

=back

=head1 EXAMPLES

Provision an Oracle VDB using latest snapshot

 dx_provision_vdb -d Landshark -sourcename "Employee Oracle DB" -dbname autoprov -targetname autoprov -group Analytics -environment LINUXTARGET -type oracle -envinst "/u01/app/oracle/product/11.2.0/dbhome_1"
 Starting provisioning job - JOB-232
 0 - 7 - 11 - 13 - 18 - 40 - 48 - 52 - 56 - 58 - 59 - 60 - 62 - 63 - 75 - 100
 Job JOB-232 finised with state: COMPLETED VDB created.

Provision a Sybase VDB using a latest snapshot

 dx_provision_vdb -d Landshark -group Analytics -sourcename 'ASE pubs3 DB' -targetname testsybase -dbname testsybase -environment LINUXTARGET -type sybase -envinst LINUXTARGET
 Starting provisioning job - JOB-158139
 0 - 11 - 15 - 75 - 100
 Job JOB-158139 finised with state: COMPLETED
 
Provision a Sybase VDB using a snapshot name "@2015-09-08T08:46:47.000" (to list snapshots use dx_get_snapshots)
 
 dx_provision_vdb -d Landshark -group Analytics -sourcename 'ASE pubs3 DB' -targetname testsybase -dbname testsybase -environment LINUXTARGET -type sybase -envinst LINUXTARGET -timestamp "@2015-09-08T08:46:47.000" 
 Starting provisioning job - JOB-158153
 0 - 11 - 15 - 63 - 100
 Job JOB-158153 finised with state: COMPLETED VDB created.

Privision a vFiles using a latest snapshot

 dx_provision_vdb -d Landshark43 -group Analytics -sourcename "files" -targetname autofs -path /mnt/provision/home/delphix -environment LINUXTARGET -type vFiles
 Starting provisioning job - JOB-798
 0 - 7 - 11 - 75 - 100
 Job JOB-798 finised with state: COMPLETED VDB created.

Privision a empty vFiles

 dx_provision_vdb -d Landshark5 -type vFiles -group "Test" -creategroup -empty -targetname "vFiles" -dbname "/home/delphix/de_mount" -environment "LINUXTARGET" -envinst "Unstructured Files"  -envUser "delphix"
 Starting provisioning job - JOB-900
 0 - 7 - 11 - 75 - 100
 Job JOB-900 finised with state: COMPLETED VDB created.

Privision a MS SQL using a latest snapshot

 dx_provision_vdb -d Landshark -group Analytics -sourcename AdventureWorksLT2008R2 -targetname autotest - dbname autotest -environment WINDOWSTARGET -type mssql -envinst MSSQLSERVER
 Starting provisioning job - JOB-158159
 0 - 3 - 11 - 18 - 75 - 100
 Job JOB-158159 finised with state: COMPLETED VDB created.

Privision a MS SQL using a snapshot from "2015-09-23 10:23"

 dx_provision_vdb -d Landshark -group Analytics -sourcename AdventureWorksLT2008R2 -targetname autotest - dbname autotest -environment WINDOWSTARGET -type mssql -envinst MSSQLSERVER -timestamp "2015-09-23 10:23" 
 Starting provisioning job - JOB-158167
 0 - 3 - 11 - 18 - 67 - 75 - 100
 Job JOB-158167 finised with state: COMPLETED VDB created.

=cut



