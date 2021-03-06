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
# Copyright (c) 2016 by Delphix. All rights reserved.
#
# Program Name : dx_ctl_js_bookmarks.pl
# Description  : Get Delphix Engine timeflow bookmarks
# Author       : Marcin Przepiorowski
# Created      : 02 Mar 2016 (v2.2.3)
#

use strict;
use warnings;
use JSON;
use Getopt::Long qw(:config no_ignore_case no_auto_abbrev); #avoids conflicts with ex host and help
use File::Basename;
use Pod::Usage;
use FindBin;
use Data::Dumper;
use warnings;
use strict;

my $abspath = $FindBin::Bin;

use lib '../lib';
use Engine;
use Formater;
use Toolkit_helpers;
use JS_template_obj;
use JS_datasource_obj;
use JS_bookmark_obj;
use JS_branch_obj;
use JS_container_obj;
use JS_operation_obj;
use Databases;


my $version = $Toolkit_helpers::version;

my $diff = 60;

GetOptions(
  'help|?' => \(my $help), 
  'd|engine=s' => \(my $dx_host), 
  'action=s'  => \(my $action), 
  'template_name=s' => \(my $template_name),
  'container_name=s' => \(my $container_name),
  'bookmark_name=s' => \(my $bookmark_name),
  'branch_name=s' => \(my $branch_name),
  'bookmark_time=s' => \(my $bookmark_time),
  'container_only' => \(my $container_only),
  'snapshots=s' => \(my $snapshots),
  'source=s' => \(my $source),
  'diff=i' => \($diff),
  'all' => (\my $all),
  'version' => \(my $print_version),
  'dever=s' => \(my $dever),
  'nohead' => \(my $nohead),
  'debug:i' => \(my $debug)
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

if ( (! defined($action) ) || ( ! ( ( $action eq 'create') || ( $action eq 'remove') ) ) ) {
  print "Option -action not defined or has invalid parameter \n";
  pod2usage(-verbose => 1,  -input=>\*DATA);
  exit (1);
}

if (lc $action eq 'create') {

  if (!defined($template_name) || (!defined($bookmark_name))) {
    print "Options template_name and bookmark_name are required \n";
    pod2usage(-verbose => 1,  -input=>\*DATA);
    exit (1);
  }

  if (! (defined($bookmark_time) || defined($snapshots) ) ) {
    print "Options bookmark_time or snapshots are required \n";
    pod2usage(-verbose => 1,  -input=>\*DATA);
    exit (1);
  }

  if (defined($bookmark_time) && defined($snapshots)) {
    print "Options bookmark_time and snapshots are mutually exclusive \n";
    pod2usage(-verbose => 1,  -input=>\*DATA);
    exit (1);
  }

  if (!defined($template_name) && defined($container_name)) {
    print "Options container_name required a template_name parametrer \n";
    pod2usage(-verbose => 1,  -input=>\*DATA);
    exit (1);
  }


  if (defined($snapshots) && ( ! ( ( lc $snapshots eq 'all' ) || ( lc $snapshots eq 'both' ) || ( lc $snapshots eq 'first' ) || ( lc $snapshots eq 'last' ) ) ) ) {
    print "Option snapshot allow the following values all, both, first, last \n";
    pod2usage(-verbose => 1,  -input=>\*DATA);
    exit (1);
  }

  if (defined($snapshots) && (!defined($source))) {
    print "Option snapshot require a source to be defined \n";
    pod2usage(-verbose => 1,  -input=>\*DATA);
    exit (1); 
  }


  if (defined($bookmark_time) && ( ! ( $bookmark_time eq 'latest' || $bookmark_time eq 'first' || $bookmark_time =~ /\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d/ ) )    ) {
    print "Wrong format of bookmark_time parameter - $bookmark_time \n";
    pod2usage(-verbose => 1,  -input=>\*DATA);
    exit (1);
  }

} elsif (lc $action eq 'remove') {
  if (!defined($template_name)) {
    print "Options template_name is required \n";
    pod2usage(-verbose => 1,  -input=>\*DATA);
    exit (1);
  }
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


  my $datalayout;
  my $datalayout_ref;
  my $bookmarks;

  if (defined($template_name)) {
    $datalayout = new JS_template_obj ( $engine_obj, $debug );
    $datalayout_ref = $datalayout->getJSTemplateByName($template_name);

    if (defined($container_name)) {
      $datalayout = new JS_container_obj ( $engine_obj, $datalayout_ref, $debug );
      $datalayout_ref = $datalayout->getJSContainerByName($container_name);
    } 
  }

  $bookmarks = new JS_bookmark_obj ( $engine_obj, undef, undef, $debug );
    

  if (!defined($datalayout_ref)) {
    print "Can't find template with a name $template_name on engine $engine \n";
    $ret = $ret + 1;
    next;    
  }

  
  my $branchs = new JS_branch_obj ( $engine_obj, $datalayout_ref, $debug );

  my $active_branch;

  if (defined($branch_name)) {
    $active_branch = $branchs->getJSBranchByName($branch_name);
    if (!defined($active_branch)) {
      print "Can't find branch with a name $branch_name in template $template_name on engine $engine \n";
      $ret = $ret + 1;
      next;
    }
  } else {
    $active_branch =  $datalayout->getJSActiveBranch($datalayout_ref);
  } 


  if (lc $action eq 'create') {

    my $datasources = new JS_datasource_obj ( $engine_obj, $datalayout_ref, undef, undef );

    if ( defined($snapshots) ) {
      


      my $ds_ref = $datasources->getJSDataSourceByName($source);

      if (!defined($ds_ref)) {
        print "Source $source in template $template_name not found. \n";
        $ret = $ret + 1;
        next;
      }

      my %bookmark_times_hash;

      my $cont = $datasources->getJSDBContainer($ds_ref);
      my $snapshot = new Snapshot_obj ( $engine_obj, $cont, 1, undef );

      if ((lc $snapshots eq 'first') || (lc $snapshots eq 'both')) {
        # find a first snapshot which can be used for bookmark ( has been taken after template was created )
        for my $snapitem ( @{ $snapshot->getSnapshots() }) {
          my $time = $snapshot->getSnapshotCreationTime($snapitem);
          my $goodtime = $datasources->checkTime($datalayout_ref, $time);
          if ( defined($goodtime) && (scalar(@{$goodtime}) > 0 )) {
            my $timename = $time;
            $timename =~ s/T/ /;
            $timename =~ s/\....Z//;
            $bookmark_times_hash{$bookmark_name . '-' . $timename} = $time;
            last;
          }
        }
      } 

      if ((lc $snapshots eq 'last') || (lc $snapshots eq 'both')) {
        my $last_time = (@{ $snapshot->getSnapshots() })[-1];

        my $time = $snapshot->getSnapshotCreationTime($last_time);
        my $goodtime = $datasources->checkTime($datalayout_ref, $time);

        if ( defined($goodtime) && (scalar(@{$goodtime}) > 0 )) {
          my $timename = $time;
          $timename =~ s/T/ /;
          $timename =~ s/\....Z//;
          $bookmark_times_hash{$bookmark_name . '-' . $timename} = $time;
        }
      }

      if (lc $snapshots eq 'all') {
        for my $snapitem ( @{ $snapshot->getSnapshots() }) {
          my $time = $snapshot->getSnapshotCreationTime($snapitem);
          my $goodtime = $datasources->checkTime($datalayout_ref, $time);

          if ( defined($goodtime) && (scalar(@{$goodtime}) > 0 )) {
            my $timename = $time;
            $timename =~ s/T/ /;
            $timename =~ s/\....Z//;
            $bookmark_times_hash{$bookmark_name . '-' . $timename} = $time;
          }
        }
      }



      for my $bookname_item (sort (keys %bookmark_times_hash)) {


        if ( $datasources->checkTimeDelta($datalayout_ref, $bookmark_times_hash{$bookname_item}, $diff ) ) {
          print "Delta between bookmark time and real time of source is bigger than $diff sec.\n"
        }

        create($bookmarks, $engine_obj, $debug, $bookname_item, $active_branch, $datalayout_ref, $bookmark_times_hash{$bookname_item}, 1);

      }

    } else {

      my $zulu;

      if (defined($template_name) && (lc $bookmark_time eq 'first') ) {
        my $firstop = $datalayout->getJSFirstOperation($datalayout_ref);


        if (defined($firstop)) {
          my $operations = new JS_operation_obj ( $engine_obj , $firstop, $debug);

          $bookmark_time = $operations->getEndTime($firstop);

          $zulu = 1;
        
        } else {
          print "Can't find a first operation for template or container \n";
          $ret = $ret + 1;
          next;
        }
      }


      if ( $datasources->checkTimeDelta($datalayout_ref, $bookmark_time, $diff ) ) {
        print "Delta between bookmark time and real time of source is bigger than $diff sec.\n"
      }



      create($bookmarks, $engine_obj, $debug, $bookmark_name, $active_branch, $datalayout_ref, $bookmark_time, $zulu);
    }
  } else {
    my $bookmarks;
    my $template_ref;


    if (defined($template_name)) {
      my $datalayout = new JS_template_obj ( $engine_obj, $debug );
      $template_ref = $datalayout->getJSTemplateByName($template_name);

      if (defined($container_name)) {
        my $container = new JS_container_obj ( $engine_obj, $template_ref, $debug );
        my $container_ref = $container->getJSContainerByName($container_name);
        $bookmarks = new JS_bookmark_obj ( $engine_obj, undef, $container_ref, $debug );
      } else {
        $bookmarks = new JS_bookmark_obj ( $engine_obj, $template_ref, undef, $debug );
      }
    }


    if (!defined($bookmarks)) {
      $bookmarks = new JS_bookmark_obj ( $engine_obj, undef, undef, $debug );
    } 
    

    my @bookmark_array;

    if (defined($bookmark_name)) {
      my $book_ref = $bookmarks->getJSBookmarkByName($bookmark_name);
      if (defined($book_ref)) {
        push(@bookmark_array, $book_ref);
      } else {
        print "Can't find bookmark name $bookmark_name \n";
        exit 1;
      }
    } else {
      @bookmark_array = @{$bookmarks->getJSBookmarkList($container_only)};
    }


    for my $bookmarkitem (@bookmark_array) {
      #print Dumper $bookmarkitem;
      my $jobno = $bookmarks->deleteBookmark($bookmarkitem);
      $bookmark_name = $bookmarks->getName($bookmarkitem);
      if (defined ($jobno) ) {
        print "Starting job $jobno for bookmark $bookmark_name.\n";
        my $job = new Jobs_obj($engine_obj, $jobno, 'true', $debug);

        my $jobstat = $job->waitForJob();
        if ($jobstat ne 'COMPLETED') {
          $ret = $ret + 1;
        }
      } else {
        print "Job for bookmark is not deleted. \n";
        $ret = $ret + 1;
      }
    }
  }
}

exit $ret;

sub create {
  my $bookmarks = shift;
  my $engine_obj = shift;
  my $debug = shift;
  my $bookmark_name = shift;
  my $active_branch = shift;
  my $datalayout_ref = shift;
  my $bookmark_time = shift;
  my $zulu = shift;

  my $jobno = $bookmarks->createBookmark($bookmark_name, $active_branch, $datalayout_ref, $bookmark_time, $zulu);

  if (defined ($jobno) ) {
    print "Starting job $jobno for bookmark $bookmark_name.\n";
    my $job = new Jobs_obj($engine_obj, $jobno, 'true', $debug);

    my $jobstat = $job->waitForJob();
    if ($jobstat ne 'COMPLETED') {
      $ret = $ret + 1;
    }
  } else {
    print "Job for bookmark is not created. \n";
    $ret = $ret + 1;
  }

}


__DATA__

=head1 SYNOPSIS

 dx_ctl_js_bookmarks.pl [ -engine|d <delphix identifier> | -all ] 
                         -action create | remove
                         -template_name template_name
                         -container_name container_name 
                         -bookmark_name bookmark_name 
                        [-bookmark_time "YYYY-MM-DD HH24:MI:SS" | first | latest ]
                        [-snapshots first | last | both | all]
                        [-source source_name]
                        [-container_name container_name]  
                        [ --help|? ] [ -debug ]

=head1 DESCRIPTION

Create or remove the Jet Stream bookmarks on Delphix Engine.

=head1 ARGUMENTS

Delphix Engine selection - if not specified a default host(s) from dxtools.conf will be used.

=over 10

=item B<-engine|d>
Specify Delphix Engine name from dxtools.conf file

=item B<-all>
Display databases on all Delphix appliance

=back

=head2 Options

=over 4

=item B<-action action_name>
Action name. Allowed values are : 

create - to create bookmark

remove - to delete bookmark ( be aware that without bookmark_name - all bookmarks from template or container will be deleted)

=item B<-template_name template_name>
Set templare for bookmark using template name

=item B<-container_name container_name>
Set container for bookmark using container name

=item B<-bookmark_name bookmark_name>
Set bookmark name

=item B<-bookmark_time time>
Set bookmark time. Allowed values:

- "YYYY-MM-DD HH:MI:SS" - timestamp (24h)

- first - use a branch creation time for bookmark (for template or container)

- latest - use latest possible time from container or template (now)

=item B<-source source_name>
Set source name used for snapshot based bookmark creation

=item B<-snapshots snapshot>
Use snapshot from source to create bookmarks. Allowed values:

=over 3

=item B<-all> - create bookmarks for all snapshot of source created after template was created

=item B<-first> - create bookmark for a first snapshot of source after template was created

=item B<-last>  - create bookmark for a last snapshot of source after template was created

=back

=back

=head1 OPTIONS

=over 3

=item B<-help>          
Print this screen

=item B<-debug>
Turn on debugging


=back

=head1 EXAMPLES

Create template bookmarks for all snapshots for template "template"" and source "oracle", bookmarks name starts with prefix "pre" 
plus time of snapshot, 

 dx_ctl_js_bookmarks.pl -d Landshark5 -bookmark_name "pre" -template_name template -snapshots all -source oracle -action create
 Starting job JOB-7623 for bookmark pre-2016-10-12 12:02:31.
 5 - 100
 Job JOB-7623 finished with state: COMPLETED

Create template bookmark for a first snapshot of source "oracle" taken after template was created

 dx_ctl_js_bookmarks -d Landshark5 -bookmark_name "firstsnap" -template_name template -snapshots first -source oracle -action create
 Starting job JOB-7625 for bookmark firstsnap-2016-10-12 12:02:31.
 5 - 100
 Job JOB-7625 finished with state: COMPLETED

Create template bookmark for particular time 

 dx_ctl_js_bookmarks -d Landshark5 -bookmark_name "fixeddate" -template_name template -bookmark_time "2016-10-12 13:05:02" -branch_name master -action create
 Starting job JOB-7626 for bookmark fixeddate.
 5 - 100
 Job JOB-7626 finished with state: COMPLETED

Create container bookmart for latest point

 dx_ctl_js_bookmarks -d Landshark5 -bookmark_name "cont_now" -bookmark_time latest -container_name cont1 -action create -template_name template
 Starting job JOB-7627 for bookmark cont_now.
 5 - 43 - 100
 Job JOB-7627 finished with state: COMPLETED

Deleting bookmark for template

 dx_ctl_js_bookmarks -d Landshark5 -bookmark_name "firstsnap-2016-10-12 12:02:31" -action remove -template_name template
 Starting job JOB-7629 for bookmark firstsnap-2016-10-12 12:02:31.
 0 - 100
 Job JOB-7629 finished with state: COMPLETED

=cut



