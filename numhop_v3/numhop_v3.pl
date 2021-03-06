#!/usr/bin/perl

#---------------------------------------
#
# Use clauses
#
#---------------------------------------
use strict;
use LWP::UserAgent;
use HTTP::Request;
use HTTP::Response;
use HTTP::Cookies;
use HTTP::Request::Common;
use Getopt::Long;
use Data::Dumper;
use File::Basename;
use XML::Simple;
#use LWP::Debug qw(+); # uncomment this to see LWP debug messages

#---------------------------------------
#
# Globals
#
#---------------------------------------
my $appname = basename($0);
my $version = '1.0.0';
my ($username, $password, $startdate, $format, $path, $help, $aglist, $usefile, $scandate,
    $proxy, $proxy_username, $proxy_password, $debug, $file, $server_url) = ('', '', '', '', '', '', '', '', '', '', '', '', '', '', '');

# Get command line options
GetOptions('username=s'       => \$username,
           'password=s'       => \$password,
           'proxy=s'          => \$proxy,
           'proxy_username=s' => \$proxy_username,
           'proxy_password=s' => \$proxy_password,
           'debug'            => \$debug,
           'help'             => \$help,
           'ag=s'             => \$aglist,
           'sincedate=s'      => \$scandate,
           'usefile'          => \$usefile,         
           'serverurl=s'      => \$server_url);

# Does the user want help?
usage() if ($help);

# Make sure we have all the arguments.
my $msg = '';
my $errStr = 'ERROR - Missing argument';
$msg .= 'username,' unless ($username);
$msg .= 'password,' unless ($password);
$msg .= 'serverurl,' unless ($server_url);
# Get rid of a trailing comma for neatness
chop($msg);

# Make message plural or not
$errStr .= 's' if ($msg =~ /,/);
usage("$errStr: $msg") if ($msg);

# Default to one month ago if not found
my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);
# Fix year
$year += 1900;
# Month is already zero-based; wrap to december ("11") if it's January
$mon = 11 if ($mon == 0);
if ($mday < 10) {
	$scandate = $year.'-'.$mon.'-0'.$mday unless ($scandate);
	}
$scandate = $year.'-'.$mon.'-'.$mday unless ($scandate);

# Set up URL
my $qualysurl = $server_url;

# Set default AG
$aglist = 'All' unless ($aglist);

# Emit starting timestamp
print "$appname starting at: $hour:$min:$sec\n" if ($debug);

# Configure the user agent
$ENV{'HTTPS_PROXY'} = $proxy if ($proxy);
$ENV{'HTTPS_PROXY_USERNAME'} = $proxy_username if ($proxy_username);
$ENV{'HTTPS_PROXY_PASSWORD'} = $proxy_password if ($proxy_password);
$ENV{HTTPS_PKCS12_FILE}     = '';
$ENV{HTTPS_PKCS12_PASSWORD} = '';
my $agent_string = $appname .'$Revision: '.$version.' $';
my $ua = LWP::UserAgent->new('agent'                => $agent_string,
                             'requests_redirectable' => [],
                             'timeout'               => 900);
$ua->default_header('X-Requested-With' => $agent_string);
$ua->cookie_jar({});
my $cookiejar = HTTP::Cookies->new();

#---------------------------------------
#
# Main script starts here
#
#---------------------------------------

# Do the login
my $sessionCookie;
$sessionCookie = login() unless ($usefile);

# Get the IGs
&getHop();

# Write them
&writeHop();

# Logout and quit.
logout() if ($sessionCookie);

# ending timestamp
($sec,$min,$hour,$mday,$mon,$year) = localtime(time);
print "$appname finished at: $hour:$min:$sec\n" if ($debug);
exit(0);

# Indicate which command line arguments are supported and/or required
sub usage {
  my $msg = shift;
  $msg = "$appname $version" unless $msg;
  print <<EOF;

$msg 

$appname [arguments]

  Required Arguments:

    --username=SOMEUSER          QualysGuard username
    --password=SOMEPASS          Password for username
    --serverurl=https://SOMEURL  Platform server url for launching reports

  Optional Arguments:

    --proxy=http://SOMEURL       HTTPS proxy URL
    --proxy_username=SOMEUSER    HTTPS proxy USERNAME
    --proxy_password=SOMEPASS    HTTPS proxy PASSWORD
    --debug=y                    Outputs additional information
    --ag=SOMEAGS                 Asset groups to get times for; if unspecified it will get All
    --sincedate=YYYY-MM-DD       Only show for hosts scanned since YYYY-MM-DD; defaults to 1 month ago
    --help                       Provide usage information (what you are reading)

$appname will get the traceroute information for the specified asset groups and timeframe and will then calculate:

* Number of hosts
* Average number of hops
* Standard deviation
* Systems FAR from their scanner (those with more hops than 68% of all others ~ AVERAGE + 1*STDEV)
* Systems CLOSE to their scanner (those with less hops than 68% of all others ~ AVERAGE - 1*STDEV)

EOF

    exit(1);
}

# Log in the global $ua object and set the QualysSession cookie
# or die with an error.
sub login {
    print "Logging in...\n";
    my $r = POST($qualysurl . '/api/2.0/fo/session/',
                 ['action' => 'login',
                  'username' => $username,
                  'password' => $password]);
    my $response = $ua->request($r);
    print "DEBUG - Login response:\n" . $response->content if ($debug);
    die("Login failed with info:\n".Dumper($response)) unless ($response->is_success);
    
    # Get the session cookie - it looks like this:
    # QualysSession=b91647c540ab2d45edde245c7b9a9db1; path=/api; secure
    my $cookie = $response->{'_headers'}->{'set-cookie'};
    $cookie =~ m/QualysSession=(.*);.*;.*/;
    return ($1);
}

# Log out the global $ua object or die with an error.
sub logout {
    print "Logging out...\n";
    my $response = $ua->post($qualysurl . '/api/2.0/fo/session/', ['action' => 'logout']);
    print "DEBUG - Logout response:\n" . $response->content if ($debug);
    die("Logout failed with info:\n".Dumper($response)) unless ($response->is_success);
}

# Log out the global $ua object (so as not to leave a dangling
# FO session), print the passed message, and die.
sub quit {
    my($msg, @junk) = @_;
    logout();
    die($msg);
}

# Get a listing all all unscanned hosts IPs
sub getHop {
    my $r;

		print "Fetching traceroute information\n";    
    # Skip if we should use the file that exists
    return if (($usefile) && (-e 'hoplist.xml'));
    
    $r = POST($qualysurl . '/api/2.0/fo/asset/host/vm/detection/',
                 ['action' => 'list',
                  'ag_titles' => $aglist,
                  'show_igs' => '1',
                  'qids' => '45006',
                  'truncation_limit' => '0',
                  'vm_scan_since' => $scandate,
                 ]);    
  my $response = $ua->request($r);
  open(MYFILE, ">hoplist.xml");
  binmode(MYFILE);
  print MYFILE $response->content;
  close(MYFILE);
      
}

# Routine to spit out CSV

sub writeHop
{
    # Grab the XML for parsing

    my $xmlRef = XMLin('hoplist.xml');
    my $total = 0;
    my $count = 0;
    my $stddev = 0;
    my %hopHash;
        

    # Loop throught the results
    foreach my $hostEntry (@{$xmlRef->{RESPONSE}->{HOST_LIST}->{HOST}}) {

    my $hostIP = $hostEntry->{IP};
    my $hostOS = $hostEntry->{OS};
    my $hopEntry = $hostEntry->{DETECTION_LIST}->{DETECTION}->{RESULTS};
	  #$hopEntry =~ m/ation: (\d*) sec/;
	  my $numofhop = $hopEntry =~ tr/\n//;
	  # Add an entry for averages
	  
	  $total += $numofhop;
	  $count++;
	  $hopHash{$hostIP} = {os => $hostOS, hop => $numofhop};
	  
    } 
    
    # Don't bother if nothing found
    unless ($count) {
    	print "Nothing found...please check your parameters.\n";
    	return;
    }
    
    # Now calculate average and STD DEV
    my $avg = int($total/$count);
	foreach my $ip (keys %hopHash) {
		# Take the square of the difference from the mean
		$stddev += (($hopHash{$ip}->{hop} - $avg)**2);
	}
	# Divide by population
	$stddev = ($stddev/$count);
	# Take square root of sum of squares for standard deviation
    $stddev = int($stddev**.5);
    
    # Print stats
    print "\nFor AGs: $aglist\nNumber of IPs: $count\nAverage number of hops: $avg\nSTDDEV: $stddev\n\n";
    # Lastly, print everybody who is outside of 2 STDDEVs
    my $toofar = $avg + (1*$stddev);
    my $veryclose = $avg - (1*$stddev);
    my (@far, @close);
    foreach my $ip (sort keys %hopHash) {
    	push(@far, "$ip ($hopHash{$ip}->{os}): $hopHash{$ip}{hop} hops\n") if ($hopHash{$ip}->{hop} > $toofar);
    	push(@close, "$ip ($hopHash{$ip}->{os}): $hopHash{$ip}{hop} hops\n") if ($hopHash{$ip}->{hop} < $veryclose);    	
    }
    print "Far systems:\n";
    my $didone = 0;
    foreach my $farguy (@far) {
    	print $farguy;
    	$didone++;
    }
    print "No far systems.\n" unless ($didone);
    $didone = 0;

    print "\nClose systems:\n";
    foreach my $closeguy (@close) {
    	print $closeguy;
    	$didone++;
    }

    print "No close systems.\n" unless ($didone);
    print "\n";
}
