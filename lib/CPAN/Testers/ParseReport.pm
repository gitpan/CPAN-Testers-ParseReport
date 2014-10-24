package CPAN::Testers::ParseReport;

use warnings;
use strict;

use Config::Perl::V ();
use DateTime::Format::Strptime;
use File::Basename qw(basename);
use File::Path qw(mkpath);
use HTML::Entities qw(decode_entities);
use LWP::UserAgent;
use List::Util qw(max min sum);
use MIME::QuotedPrint ();
use Time::Local ();
use XML::LibXML;
use XML::LibXML::XPathContext;

our $default_ctformat = "yaml";
our $default_transport = "http_cpantesters";
our $default_cturl = "http://www.cpantesters.org/show";
our $Signal = 0;

=encoding utf-8

=head1 NAME

CPAN::Testers::ParseReport - parse reports to www.cpantesters.org from various sources

=cut

use version; our $VERSION = qv('0.1.17');

=head1 SYNOPSIS

The documentation in here is normally not needed because the code is
meant to be run from the standalone program C<ctgetreports>.

  ctgetreports --q mod:Moose Devel-Events

=head1 DESCRIPTION

This is the core module for CPAN::Testers::ParseReport. If you're not
looking to extend or alter the behaviour of this module, you probably
want to look at L<ctgetreports> instead.

=head1 OPTIONS

Options are described in the L<ctgetreports> manpage and are passed
through to the functions unaltered.

=head1 FUNCTIONS

=head2 parse_distro($distro,%options)

reads the cpantesters HTML page or the YAML file or the local database
for the distro and loops through the reports for the specified or most
recent version of that distro found in these data.

parse_distro() intentionally has no meaningful return value, different
options would require different ones.

=head2 $extract = parse_single_report($report,$dumpvars,%options)

mirrors and reads this report. $report is of the form

  { id => number }

$dumpvar is a hashreference that gets filled with data.

$extract is the result of parse_report() described below.

=cut

{
    my $ua;
    sub _ua {
        return $ua if $ua;
        $ua = LWP::UserAgent->new
            (
             keep_alive => 1,
             env_proxy => 1,
            );
        $ua->parse_head(0);

        # I would love to support gzipped transfer but it doesn't seem
        # to mix well with mirroring:

        # $ua->default_header('Accept-Encoding' => scalar HTTP::Message::decodable());

        $ua;
    }
}

{
    my $xp;
    sub _xp {
        return $xp if $xp;
        $xp = XML::LibXML->new;
        $xp->keep_blanks(0);
        $xp->clean_namespaces(1);
        my $catalog = __FILE__;
        $catalog =~ s|ParseReport.pm$|ParseReport/catalog|;
        $xp->load_catalog($catalog);
        return $xp;
    }
}

sub _download_overview {
    my($cts_dir, $distro, %Opt) = @_;
    my $format = $Opt{ctformat} ||= $default_ctformat;
    my $cturl = $Opt{cturl} ||= $default_cturl;
    my $ctarget = "$cts_dir/$distro.$format";
    my $cheaders = "$cts_dir/$distro.headers";
    if ($Opt{local}) {
        unless (-e $ctarget) {
            die "Alert: No local file '$ctarget' found, cannot continue\n";
        }
    } else {
        if (! -e $ctarget or -M $ctarget > .25) {
            if (-e $ctarget && $Opt{verbose}) {
                my(@stat) = stat _;
                my $timestamp = gmtime $stat[9];
                print STDERR "(timestamp $timestamp GMT)\n" unless $Opt{quiet};
            }
            print STDERR "Fetching $ctarget..." if $Opt{verbose} && !$Opt{quiet};
            my $uri = "$cturl/$distro.$format";
            my $resp = _ua->mirror($uri,$ctarget);
            if ($resp->is_success) {
                print STDERR "DONE\n" if $Opt{verbose} && !$Opt{quiet};
                open my $fh, ">", $cheaders or die;
                for ($resp->headers->as_string) {
                    print $fh $_;
                    if ($Opt{verbose} && $Opt{verbose}>1) {
                        print STDERR $_ unless $Opt{quiet};
                    }
                }
            } elsif (304 == $resp->code) {
                print STDERR "DONE (not modified)\n" if $Opt{verbose} && !$Opt{quiet};
                my $atime = my $mtime = time;
                utime $atime, $mtime, $cheaders;
            } else {
                die sprintf
                    (
                     "No success downloading %s: %s",
                     $uri,
                     $resp->status_line,
                    );
            }
        }
    }
    return $ctarget;
}

sub _parse_html {
    my($ctarget, %Opt) = @_;
    my $content = do { open my $fh, $ctarget or die; local $/; <$fh> };
    my $preprocesswithtreebuilder = 0; # not needed since barbie switched to XHTML
    if ($preprocesswithtreebuilder) {
        require HTML::TreeBuilder;
        my $tree = HTML::TreeBuilder->new;
        $tree->implicit_tags(1);
        $tree->p_strict(1);
        $tree->ignore_ignorable_whitespace(0);
        $tree->parse_content($content);
        $tree->eof;
        $content = $tree->as_XML;
    }
    my $parser = _xp();
    my $doc = eval { $parser->parse_string($content) };
    my $err = $@;
    unless ($doc) {
        my $distro = basename $ctarget;
        die sprintf "Error while parsing %s\: %s", $distro, $err;
    }
    my $xc = XML::LibXML::XPathContext->new($doc);
    my $nsu = $doc->documentElement->namespaceURI;
    $xc->registerNs('x', $nsu) if $nsu;
    my($selected_release_ul,$selected_release_distrov,$excuse_string);
    my($cparentdiv)
        = $nsu ?
            $xc->findnodes("/x:html/x:body/x:div[\@id = 'doc']") :
                $doc->findnodes("/html/body/div[\@id = 'doc']");
    my(@releasedivs) = $nsu ?
        $xc->findnodes("//x:div[x:h2 and x:ul]",$cparentdiv) :
            $cparentdiv->findnodes("//div[h2 and ul]");
    my $releasediv;
    if ($Opt{vdistro}) {
        $excuse_string = "selected distro '$Opt{vdistro}'";
        my($fallbacktoversion) = $Opt{vdistro} =~ /(\d+\..*)/;
        $fallbacktoversion = 0 unless defined $fallbacktoversion;
      RELEASE: for my $i (0..$#releasedivs) {
            my $picked = "";
            my($x) = $nsu ?
                $xc->findvalue("x:h2/x:a[2]/\@name",$releasedivs[$i]) :
                    $releasedivs[$i]->findvalue("h2/a[2]/\@name");
            if ($x) {
                if ($x eq $Opt{vdistro}) {
                    $releasediv = $i;
                    $picked = " (picked)";
                }
                print STDERR "FOUND DISTRO: $x$picked\n" unless $Opt{quiet};
            } else {
                ($x) = $nsu ?
                    $xc->findvalue("x:h2/x:a[1]/\@name",$releasedivs[$i]) :
                        $releasedivs[$i]->findvalue("h2/a[1]/\@name");
                if ($x eq $fallbacktoversion) {
                    $releasediv = $i;
                    $picked = " (picked)";
                }
                print STDERR "FOUND VERSION: $x$picked\n" unless $Opt{quiet};
            }
        }
    } else {
        $excuse_string = "any distro";
    }
    unless (defined $releasediv) {
        $releasediv = 0;
    }
    # using a[1] because a[2] is missing on the first entry
    ($selected_release_distrov) = $nsu ?
        $xc->findvalue("x:h2/x:a[1]/\@name",$releasedivs[$releasediv]) :
            $releasedivs[$releasediv]->findvalue("h2/a[1]/\@name");
    ($selected_release_ul) = $nsu ?
        $xc->findnodes("x:ul",$releasedivs[$releasediv]) :
            $releasedivs[$releasediv]->findnodes("ul");
    unless (defined $selected_release_distrov) {
        warn "Warning: could not find $excuse_string in '$ctarget'";
        return;
    }
    print STDERR "SELECTED: $selected_release_distrov\n" unless $Opt{quiet};
    my($id);
    my @all;
    for my $test ($nsu ?
                  $xc->findnodes("x:li",$selected_release_ul) :
                  $selected_release_ul->findnodes("li")) {
        $id = $nsu ?
            $xc->findvalue("x:a[1]/text()",$test)     :
                $test->findvalue("a[1]/text()");
        push @all, {id=>$id};
        return if $Signal;
    }
    return \@all;
}

sub _parse_yaml {
    my($ctarget, %Opt) = @_;
    require YAML::Syck;
    my $arr = YAML::Syck::LoadFile($ctarget);
    my($selected_release_ul,$selected_release_distrov,$excuse_string);
    if ($Opt{vdistro}) {
        $excuse_string = "selected distro '$Opt{vdistro}'";
        $arr = [grep {$_->{distversion} eq $Opt{vdistro}} @$arr];
        ($selected_release_distrov) = $arr->[0]{distversion};
    } else {
        $excuse_string = "any distro";
        my $last_addition;
        my %seen;
        for my $report (sort { $a->{id} <=> $b->{id} } @$arr) {
            unless ($seen{$report->{distversion}}++) {
                $last_addition = $report->{distversion};
            }
        }
        $arr = [grep {$_->{distversion} eq $last_addition} @$arr];
        ($selected_release_distrov) = $last_addition;
    }
    unless ($selected_release_distrov) {
        warn "Warning: could not find $excuse_string in '$ctarget'";
        return;
    }
    print STDERR "SELECTED: $selected_release_distrov\n" unless $Opt{quiet};
    my @all;
    for my $test (@$arr) {
        my $id = $test->{id};
        push @all, {id=>$id};
        return if $Signal;
    }
    @all = sort { $b->{id} <=> $a->{id} } @all;
    return \@all;
}

sub parse_single_report {
    my($report, $dumpvars, %Opt) = @_;
    my($id) = $report->{id};
    $Opt{cachedir} ||= "$ENV{HOME}/var/cpantesters";
    my $nnt_dir = "$Opt{cachedir}/nntp-testers";
    mkpath $nnt_dir;
    my $target = "$nnt_dir/$id";
    if ($Opt{local}) {
        unless (-e $target) {
            die {severity=>0,text=>"Warning: No local file '$target' found, skipping\n"};
        }
    } else {
        if (! -e $target) {
            print STDERR "Fetching $target..." if $Opt{verbose} && !$Opt{quiet};
            $Opt{transport} ||= $default_transport;
            if (0) {
            } elsif ($Opt{transport} eq "http_cpantesters") {
                my $resp = _ua->mirror("http://www.cpantesters.org/cgi-bin/pages.cgi?act=cpan-report&raw=1&id=$id",$target);
                if ($resp->is_success) {
                    if ($Opt{verbose}) {
                        my(@stat) = stat $target;
                        my $timestamp = gmtime $stat[9];
                        print STDERR "(timestamp $timestamp GMT)\n" unless $Opt{quiet};
                        if ($Opt{verbose} > 1) {
                            print STDERR $resp->headers->as_string unless $Opt{quiet};
                        }
                    }
                    my $headers = "$target.headers";
                    open my $fh, ">", $headers or die {severity=>1,text=>"Could not open >$headers: $!"};
                    print $fh $resp->headers->as_string;
                } else {
                    die {severity=>0,
                             text=>sprintf "HTTP Server Error[%s] for id[%s]", $resp->status_line, $id};
                }
            } elsif ($Opt{transport} eq "http_cpantesters_gzip") {
                if (-e "$target.gz") {
                    0 == system gunzip => $target or die;
                }
                my $resp = _ua->mirror("http://www.cpantesters.org/cgi-bin/pages.cgi?act=cpan-report&raw=1&id=$id",$target);
                if ($resp->is_success) {
                    if ($Opt{verbose}) {
                        my(@stat) = stat $target;
                        my $timestamp = gmtime $stat[9];
                        print STDERR "(timestamp $timestamp GMT)\n" unless $Opt{quiet};
                        if ($Opt{verbose} > 1) {
                            print STDERR $resp->headers->as_string unless $Opt{quiet};
                        }
                    }
                    my $headers = "$target.headers";
                    open my $fh, ">", $headers or die {severity=>1,text=>"Could not open >$headers: $!"};
                    print $fh $resp->headers->as_string;
                    0 == system gzip => $target or die;
                } else {
                    die {severity=>0,
                             text=>sprintf "HTTP Server Error[%s] for id[%s]", $resp->status_line, $id};
                }
            } else {
                die {severity=>1,text=>"Illegal value for --transport: '$Opt{transport}'"};
            }
        }
    }
    parse_report($target, $dumpvars, %Opt);
}

sub parse_distro {
    my($distro,%Opt) = @_;
    my %dumpvars;
    $Opt{cachedir} ||= "$ENV{HOME}/var/cpantesters";
    my $cts_dir = "$Opt{cachedir}/cpantesters-show";
    mkpath $cts_dir;
    if ($Opt{solve}) {
        require Statistics::Regression;
        $Opt{dumpvars} = "." unless defined $Opt{dumpvars};
    }
    if (!$Opt{vdistro} && $distro =~ /^(.+)-(?i:v?\d+)(?:\.\d+)*\w*$/) {
        $Opt{vdistro} = $distro;
        $distro = $1;
    }
    my $reports;
    if (my $ctdb = $Opt{ctdb}) {
        require CPAN::WWW::Testers::Generator::Database;
        require CPAN::DistnameInfo;
        my $dbi = CPAN::WWW::Testers::Generator::Database->new(database=>$ctdb) or die "Alert: unknown error while opening database '$ctdb'";
        unless ($Opt{vdistro}) {
            my $sql = "select version from cpanstats where dist=? order by id";
            my @rows = $dbi->get_query($sql,$distro);
            my($newest,%seen);
            for my $row (@rows) {
                $newest = $row->[0] unless $seen{$row->[0]}++;
            }
            $Opt{vdistro} = "$distro-$newest";
        }
        my $d = CPAN::DistnameInfo->new("FOO/$Opt{vdistro}.tgz");
        my $dist = $d->dist;
        my $version = $d->version;
        my $sql = "select id from cpanstats where dist=? and version=? order by id desc";
        my @rows = $dbi->get_query($sql,$dist,$version);
        my @all;
        for my $row (@rows) {
            my $id = $row->[0];
            push @all, {id=>$id};
        }
        $reports = \@all;
    } else {
        my $ctarget = _download_overview($cts_dir, $distro, %Opt);
        $Opt{ctformat} ||= $default_ctformat;
        if ($Opt{ctformat} eq "html") {
            $reports = _parse_html($ctarget,%Opt);
        } else {
            $reports = _parse_yaml($ctarget,%Opt);
        }
    }
    return unless $reports;
    my $sampled = 0;
    my $i = 0;
    my $samplesize = $Opt{sample} || 0;
    $samplesize = 0 if $samplesize && $samplesize >= @$reports;
 REPORT: for my $report (@$reports) {
        $i++;
        if ($samplesize) {
            my $need = $samplesize - $sampled;
            next REPORT unless $need;
            my $left = @$reports - $i;
            # warn sprintf "tot %d i %d sampled %d need %d left %d\n", scalar @$reports, $i, $sampled, $need, $left;
            my $want_this = (rand(1) <= ($need/$left));
            next REPORT unless $want_this;
        }
        eval {parse_single_report($report, \%dumpvars, %Opt)};
        if ($@) {
            if (ref $@) {
                if ($@->{severity}) {
                    die $@->{text};
                } else {
                    warn $@->{text};
                }
            } else {
                die $@;
            }
        }
        $sampled++;
        last if $Signal;
    }
    if ($Opt{dumpvars}) {
        require YAML::Syck;
        my $dumpfile = $Opt{dumpfile} || "ctgetreports.out";
        open my $fh, ">", $dumpfile or die "Could not open '$dumpfile' for writing: $!";
        print $fh YAML::Syck::Dump(\%dumpvars);
        close $fh or die "Could not close '$dumpfile': $!"
    }
    if ($Opt{solve}) {
        solve(\%dumpvars,%Opt);
    }
}

=head2 $bool = _looks_like_qp($raw_report)

We had to acknowledge the fact that some MTAs swallow the MIME-Version
header while passing MIME through. So we introduce fallback heuristics
that try to determine if a report is written in quoted printable.

Note that this subroutine is internal, just documented to have the
internals documented.

The current implementation counts the number of QP escaped spaces and
equal signs.

=cut

sub _looks_like_qp {
    my($report) = @_;
    my $count_space = () = $report =~ /=20/g;
    return 1 if $count_space > 12;
    my $count_equal = () = $report =~ /=3D/g;
    return 1 if $count_equal > 12;
    return 1 if $count_space+$count_equal > 24;
    return 0; # waiting for a counter example
}

=head2 $extract = parse_report($target,$dumpvars,%Opt)

Reads one report. $target is the local filename to read. $dumpvars is
a hashref which gets filled with descriptive stats about
PASS/FAIL/etc. %Opt are the options as described in the
C<ctgetreports> manpage. $extract is a hashref containing the found
variables.

Note: this parsing is a bit dirty but as it seems good enough I'm not
inclined to change it. We parse HTML with regexps only, not an HTML
parser. Only the entities are decoded.

In %Opt you can use

    article => $some_full_article_as_scalar

to use this function to parse one full article as text. When this is
given, the argument $target is not read, but its basename is taken to
be the id of the article. (OMG, hackers!)

=cut
sub parse_report {
    my($target,$dumpvars,%Opt) = @_;
    our @q;
    my $id = basename($target);
    # warn "DEBUG: id[$id]";
    my($ok,$about);

    my(%extract);

    my($report,$isHTML) = _get_cooked_report($target, \%Opt);
    my @qr = map /^qr:(.+)/, @{$Opt{q}};
    if ($Opt{raw} || @qr) {
        for my $qr (@qr) {
            my $cqr = eval "qr{$qr}";
            die "Could not compile regular expression '$qr': $@" if $@;
            my(@matches) = $report =~ $cqr;
            my $v;
            if (@matches) {
                if (@matches==1) {
                    $v = $matches[0];
                } else {
                    $v = join "", map {"($_)"} @matches;
                }
            } else {
                $v = "";
            }
            $extract{"qr:$qr"} = $v;
        }
    }

    my $report_writer;
    my $moduleunpack = {};
    my $expect_prereq = 0;
    my $expect_toolchain = 0;
    my $expecting_toolchain_soon = 0;
    my $fallback_p5 = "";

    my $in_summary = 0;
    my $in_summary_seen_platform = 0;
    my $in_prg_output = 0;
    my $in_env_context = 0;

    my $current_headline;
    my @previous_line = ""; # so we can neutralize line breaks
    my @rlines = split /\r?\n/, $report;
 LINE: for (@rlines) {
        next LINE unless ($isHTML ? m/<title>((\S+)\s+(\S+))/ : m/^Subject:\s*((\S+)\s+(\S+))/);
        my $s = $1;
        $s = $1 if $s =~ m{<strong>(.+)};
        if ($s =~ /(\S+)\s+(\S+)/) {
            $ok = $1;
            $about = $2;
        }
        $extract{"meta:ok"}    = $ok;
        $extract{"meta:about"} = $about;
        last;
    }
    unless ($extract{"meta:about"}) {
        $extract{"meta:about"} = $Opt{vdistro};
        unless ($extract{"meta:ok"}) {
            $DB::single++;
            warn "Warning: could not determine state of report";
        }
    }
 LINE: while (@rlines) {
        $_ = shift @rlines;
        while (/!$/ and @rlines) {
            my $followupline = shift @rlines;
            $followupline =~ s/^\s+//; # remo leading space
            $_ .= $followupline;
        }
        if (/^--------/ && $previous_line[-2] && $previous_line[-2] =~ /^--------/) {
            $current_headline = $previous_line[-1];
            if ($current_headline =~ /PROGRAM OUTPUT/) {
                $in_prg_output = 1;
            } else {
                $in_prg_output = 0;
            }
            if ($current_headline =~ /ENVIRONMENT AND OTHER CONTEXT/) {
                $in_env_context = 1;
            } else {
                $in_env_context = 0;
            }
        }
        if ($extract{"meta:perl"}) {
            if (    $in_summary
                and !$extract{"conf:git_commit_id"}
                and /Commit id:\s*([[:xdigit:]]+)/) {
                $extract{"conf:git_commit_id"} = $1;
            }
        } else {
            my $p5;
            if (0) {
            } elsif (/Summary of my perl5 \((.+)\) configuration:/) {
                $p5 = $1;
                $in_summary = 1;
                $in_env_context = 0;
            }
            if ($p5) {
                my($r,$v,$s,$p);
                if (($r,$v,$s,$p) = $p5 =~ /revision (\S+) version (\S+) subversion (\S+) patch (\S+)/) {
                    $r =~ s/\.0//; # 5.0 6 2!
                    $extract{"meta:perl"} = "$r.$v.$s\@$p";
                } elsif (($r,$v,$s) = $p5 =~ /revision (\S+) version (\S+) subversion (\S+)/) {
                    $r =~ s/\.0//;
                    $extract{"meta:perl"} = "$r.$v.$s";
                } elsif (($r,$v,$s) = $p5 =~ /(\d+\S*) patchlevel (\S+) subversion (\S+)/) {
                    $r =~ s/\.0//;
                    $extract{"meta:perl"} = "$r.$v.$s";
                } else {
                    $extract{"meta:perl"} = $p5;
                }
            }
        }
        unless ($extract{"meta:from"}) {
            if (0) {
            } elsif ($isHTML ?
                     m|<div class="h_name">From:</div> <b>(.+?)</b><br/>| :
                     m|^From:\s*(.+)|
                    ) {
                my $f = $1;
                $f = $1 if $f =~ m{<strong>(.+)</strong>};
                $extract{"meta:from"} = $f;
            }
            $extract{"meta:from"} =~ s/\.$// if $extract{"meta:from"};
        }
        unless ($extract{"meta:date"}) {
            if (0) {
            } elsif ($isHTML ?
                     m|<div class="h_name">Date:</div> (.+?)<br/>| :
                     m|^Date:\s*(.+)|
                    ) {
                my $date = $1;
                $date = $1 if $date =~ m{<strong>(.+)</strong>};
                my($dt);
            DATEFMT: for my $pat ("%Y-%m-%dT%TZ", # 2010-07-07T14:01:40Z
                                  "%a, %d %b %Y %T %z", # Sun, 28 Sep 2008 12:23:12 +0100
                                  "%b %d, %Y %R", # July 10,...
                                  "%b  %d, %Y %R", # July  4,...
                                 ) {
                    $dt = eval {
                        my $p = DateTime::Format::Strptime->new
                            (
                             locale => "en",
                             time_zone => "UTC",
                             pattern => $pat,
                            );
                        $p->parse_datetime($date)
                    };
                    last DATEFMT if $dt;
                }
                unless ($dt) {
                    warn "Could not parse date[$date], setting to epoch 0";
                    $dt = DateTime->from_epoch( epoch => 0 );
                }
                $extract{"meta:date"} = $dt->datetime;
            }
            $extract{"meta:date"} =~ s/\.$// if $extract{"meta:date"};
        }
        unless ($extract{"meta:writer"}) {
            for ("$previous_line[-1] $_") {
                if (0) {
                } elsif (/CPANPLUS, version (\S+)/) {
                    $extract{"meta:writer"} = "CPANPLUS $1";
                } elsif (/created (?:automatically )?by (\S+)/) {
                    $extract{"meta:writer"} = $1;
                    if (/\s+on\s+perl\s+([^,]+),/) {
                        $fallback_p5 = $1;
                    }
                } elsif (/This report was machine-generated by (\S+) (\S+)/) {
                    $extract{"meta:writer"} = "$1 $2";
                }
                $extract{"meta:writer"} =~ s/[\.,]$// if $extract{"meta:writer"};
            }
        }
        if ($in_summary) {
            # we do that first three lines a bit too often
            my $qr = $Opt{dumpvars} || "";
            $qr = qr/$qr/ if $qr;
            unless (@q) {
                @q = @{$Opt{q}||[]};
                @q = qw(meta:perl conf:archname conf:usethreads conf:optimize meta:writer meta:from) unless @q;
            }

            my %conf_vars = map {($_ => 1)} grep { /^conf:/ } @q;

            if (/^\s+Platform:$/) {
                $in_summary_seen_platform=1;
            } elsif (/^\s*$/ || m|</pre>|) {
                # if not html, we have reached the end now
                if ($in_summary_seen_platform) {
                    # some perls have an empty line after the summary line
                    $in_summary = 0;
                }
            } else {
                my(%kv) = /\G,?\s*([^=]+)=('[^']+?'|\S+)/gc;
                while (my($k,$v) = each %kv) {
                    my $ck = "conf:$k";
                    $ck =~ s/\s+$//;
                    $v =~ s/,$//;
                    if ($v =~ /^'(.*)'$/) {
                        $v = $1;
                    }
                    $v =~ s/^\s+//;
                    $v =~ s/\s+$//;
                    if ($qr && $ck =~ $qr) {
                        $extract{$ck} = $v;
                    } elsif ($conf_vars{$ck}) {
                        $extract{$ck} = $v;
                    }
                }
            }
        }
        if ($in_prg_output) {
            unless ($extract{"meta:output_from"}) {
                if (/Output from (.+):$/) {
                    $extract{"meta:output_from"} = $1
                }
            }
        }
        if ($in_env_context) {
            if ($extract{"meta:writer"} =~ /^CPANPLUS\b/
                ||
                exists $extract{"env:PERL5_CPANPLUS_IS_VERSION"}
               ) {
                (
                 s/Perl:\s+\$\^X/\$^X/
                 ||
                 s/EUID:\s+\$>/\$EUID/
                 ||
                 s/UID:\s+\$</\$UID/
                 ||
                 s/EGID:\s+\$\)/\$EGID/
                 ||
                 s/GID:\s+\$\(/\$GID/
                )
            }
            if (my($left,$right) = /^\s{4}(\S+)\s*=\s*(.*)$/) {
                if ($left eq '$UID/$EUID') {
                    my($uid,$euid) = split m{\s*/\s*}, $right;
                    $extract{'env:$UID'} = $uid;
                    $extract{'env:$EUID'} = $euid;
                } else {
                    $extract{"env:$left"} = $right;
                }
            }
        }
        push @previous_line, $_;
        if ($expect_prereq || $expect_toolchain) {
            if (/Perl module toolchain versions installed/) {
                # first time discovered in CPANPLUS 0.89_06
                $expecting_toolchain_soon = 1;
                $expect_prereq=0;
                next LINE;
            }
            if (exists $moduleunpack->{type}) {
                my($module,$v,$needwant);
                # type 1 and 2 are about prereqs, type three about toolchain
                if ($moduleunpack->{type} == 1) {
                    (my $leader,$module,$needwant,$v) = eval { unpack $moduleunpack->{tpl}, $_; };
                    next LINE if $@;
                    if ($leader =~ /^-/) {
                        $moduleunpack = {};
                        $expect_prereq = 0;
                        next LINE;
                    } elsif ($leader =~ /^(
                                         buil          # build_requires:
                                         |conf         # configure_requires:
                                        )/x) {
                        next LINE;
                    } elsif ($module =~ /^(
                                         -             # line drawing
                                        )/x) {
                        next LINE;
                    }
                } elsif ($moduleunpack->{type} == 2) {
                    (my $leader,$module,$v,$needwant) = eval { unpack $moduleunpack->{tpl}, $_; };
                    next LINE if $@;
                    for ($module,$v,$needwant) {
                        s/^\s+//;
                        s/\s+$//;
                    }
                    if ($leader =~ /^\*/) {
                        $moduleunpack = {};
                        $expect_prereq = 0;
                        next LINE;
                    } elsif (!defined $v
                             or !defined $needwant
                             or $v =~ /\s/
                             or $needwant =~ /\s/
                            ) {
                        ($module,$v,$needwant) = split " ", $_;
                    }
                } elsif ($moduleunpack->{type} == 3) {
                    (my $leader,$module,$v) = eval { unpack $moduleunpack->{tpl}, $_; };
                    next LINE if $@;
                    if (!$module) {
                        $moduleunpack = {};
                        $expect_toolchain = 0;
                        next LINE;
                    } elsif ($module =~ /^-/) {
                        next LINE;
                    }
                }
                $module =~ s/\s+$//;
                if ($module) {
                    $v =~ s/^\s+//;
                    $v =~ s/\s+$//;
                    my($modulename,$versionlead) = split " ", $module;
                    if (defined $modulename and defined $versionlead) {
                        $module = $modulename;
                        $v = "$versionlead$v";
                    }
                    if ($v eq "Have") {
                        next LINE;
                    }
                    $extract{"mod:$module"} = $v;
                    if ($needwant) {
                        $needwant =~ s/^\s+//;
                        $needwant =~ s/\s+$//;
                        $extract{"prereq:$module"} = $needwant;
                    }
                }
            }
            if (/(\s+)(Module\s+)(Need\s+)Have/) {
                $in_env_context = 0;
                $moduleunpack = {
                                 tpl => 'a'.length($1).'a'.length($2).'a'.length($3).'a*',
                                 type => 1,
                                };
            } elsif (/(\s+)(Module Name\s+)(Have)(\s+)Want/) {
                $in_env_context = 0;
                my $adjust_1 = 0;
                my $adjust_2 = -length($4);
                my $adjust_3 = length($4);
                # I think they do not really try to align, usually we
                # get away with split
                $moduleunpack = {
                                 tpl => 'a'.length($1).'a'.(length($2)+$adjust_2).'a'.(length($3)+$adjust_3).'a*',
                                 type => 2,
                                };
            }
        }
        if (/PREREQUISITES|Prerequisite modules loaded/) {
            $in_env_context = 0;
            $expect_prereq=1;
        }
        if ($expecting_toolchain_soon) {
            if (/(\s+)(Module(?:\sName)?\s+) Have/) {
                $in_env_context = 0;
                $expect_toolchain=1;
                $expecting_toolchain_soon=0;
                $moduleunpack = {
                                 tpl => 'a'.length($1).'a'.length($2).'a*',
                                 type => 3,
                                };
            }
        }
        if (/toolchain versions installed/) {
            $in_env_context = 0;
            $expecting_toolchain_soon=1;
        }
    }                           # LINE
    if (! $extract{"meta:perl"} && $fallback_p5) {
        my($p5,$patch) = split /\s+patch\s+/, $fallback_p5;
        $extract{"meta:perl"} = $p5;
        $extract{"conf:git_describe"} = $patch if defined $patch;
    }
    $extract{id} = $id;
    if (my $filtercbbody = $Opt{filtercb}) {
        my $filtercb = eval('sub {'.$filtercbbody.'}');
        $filtercb->(\%extract);
    }
    if ($Opt{solve}) {
        if ($extract{"conf:osvers"} && $extract{"conf:archname"}) {
            $extract{"conf:archname+osvers"} = join " ", @extract{"conf:archname","conf:osvers"};
        }
        my $data = $dumpvars->{"==DATA=="} ||= [];
        push @$data, \%extract;
    }
    # ---- %extract finished ----
    my $diag = "";
    if (my $qr = $Opt{dumpvars}) {
        $qr = qr/$qr/;
        while (my($k,$v) = each %extract) {
            if ($k =~ $qr) {
                $dumpvars->{$k}{$v}{$extract{"meta:ok"}}++;
            }
        }
    }
    for my $want (@q) {
        my $have  = $extract{$want} || "";
        $diag .= " $want\[$have]";
    }
    printf STDERR " %-4s %8d%s\n", $extract{"meta:ok"}, $id, $diag unless $Opt{quiet};
    if ($Opt{raw}) {
        $report =~ s/\s+\z//;
        print STDERR $report, "\n================\n" unless $Opt{quiet};
    }
    if ($Opt{interactive}) {
        require IO::Prompt;
        local @ARGV;
        local $ARGV;
        my $ans = IO::Prompt::prompt
            (
             -p => "View $id? [onechar: ynq] ",
             -d => "y",
             -u => qr/[ynq]/,
             -onechar,
            );
        print STDERR "\n" unless $Opt{quiet};
        if ($ans eq "y") {
	    my($report) = _get_cooked_report($target, \%Opt);
            $Opt{pager} ||= "less";
            open my $lfh, "|-", $Opt{pager} or die "Could not fork '$Opt{pager}': $!";
            local $/;
            print {$lfh} $report;
            close $lfh or die "Could not close pager: $!"
        } elsif ($ans eq "q") {
            $Signal++;
            return;
        }
    }
    return \%extract;
}

sub _get_cooked_report {
    my($target, $Opt_ref) = @_;
    my($report, $isHTML);
    if ($report = $Opt_ref->{article}) {
        $isHTML = $report =~ /^</;
        undef $target;
    }
    if ($target) {
        my $fh;
        if (0) {
        } elsif (-e $target) {
            open $fh, '<', $target or die "Could not open '$target': $!";
        } elsif (-e "$target.gz") {
            open $fh, "-|", "zcat", $target or die "Could not open '$target.gz': $!";
        } else {
            die "Could not find '$target' or '$target.gz'";
        }
        local $/;
        my $raw_report = <$fh>;
        $isHTML = $raw_report =~ /^</;
        if ($isHTML) {
            if ($raw_report =~ m{^<\?.+?<html.+?<head.+?<body.+?<pre[^>]*>(.+)</pre>.*</body>.*</html>}s) {
                $raw_report = decode_entities($1);
                $isHTML = 0;
            }
        }
        if ($isHTML) {
            $report = decode_entities($raw_report);
        } elsif ($raw_report =~ /^MIME-Version: 1.0$/m
                 ||
                 _looks_like_qp($raw_report)
                ) {
            # minimizing MIME effort; don't know about reports in other formats
            $report = MIME::QuotedPrint::decode_qp($raw_report);
        } else {
            $report = $raw_report;
        }
        close $fh;
    }
    if ($report =~ /\r\n/) {
        my @rlines = split /\r?\n/, $report;
        $report = join "\n", @rlines;
    }
    ($report, $isHTML);
}

=head2 solve

Feeds a couple of potentially interesting data to
Statistics::Regression and sorts the result by R^2 descending. Do not
confuse this with a prove, rather take it as a useful hint. It can
save you minutes of staring at data and provide a quick overview where
one should look closer. Displays the N top candidates, where N
defaults to 3 and can be set with the C<$Opt{solvetop}> variable.
Regressions results with an R^2 of 1.00 are displayed in any case.

The function is called when the option C<-solve> is give on the
commandline. Several extra config variables are calculated, see source
code for details.

=cut
{
    my %never_solve_on = map {($_ => 1)}
        (
         "conf:ccflags",
         "conf:config_args",
         "conf:cppflags",
         "conf:lddlflags",
         "conf:uname",
         "env:PATH",
         "env:PERL5LIB",
         "env:PERL5OPT",
         'env:$^X',
         'env:$EGID',
         'env:$GID',
         'env:PERL5_CPANPLUS_IS_RUNNING',
         'env:PERL5_CPAN_IS_RUNNING',
         'env:PERL5_CPAN_IS_RUNNING_IN_RECURSION',
         'meta:ok',
        );
    my %normalize_numeric =
        (
         id => sub { return shift },
         'meta:date' => sub {
             my $v = shift;
             my($Y,$M,$D,$h,$m,$s) = $v =~ /(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)/;
             unless (defined $M) {
                 die "illegal value[$v] for a date";
             }
             Time::Local::timegm($s,$m,$h,$D,$M-1,$Y);
         },
        );
    my %normalize_value =
        (
         'meta:perl' => sub {
             my($perlatpatchlevel) = shift;
             my $perl = $perlatpatchlevel;
             $perl =~ s/\@.*//;
             $perl;
         },
        );
sub solve {
    my($V,%Opt) = @_;
    require Statistics::Regression;
    my @regression;
    my $ycb;
    if (my $ycbbody = $Opt{ycb}) {
        $ycb = eval('sub {'.$ycbbody.'}');
        die if $@;
    } else {
        $ycb = sub {
            my $rec = shift;
            my $y;
            if ($rec->{"meta:ok"} eq "PASS") {
                $y = 1;
            } elsif ($rec->{"meta:ok"} eq "FAIL") {
                $y = 0;
            }
            return $y
        };
    }
  VAR: for my $variable (sort keys %$V) {
        next if $variable eq "==DATA==";
        if ($never_solve_on{$variable}){
            warn "Skipping '$variable'\n" unless $Opt{quiet};
            next VAR;
        }
        my $value_distribution = $V->{$variable};
        my $keys = keys %$value_distribution;
        my @X = qw(const);
        if ($normalize_numeric{$variable}) {
            push @X, "n_$variable";
        } else {
            my %seen = ();
            for my $value (sort keys %$value_distribution) {
                my $pf = $value_distribution->{$value};
                $pf->{PASS} ||= 0;
                $pf->{FAIL} ||= 0;
                if ($pf->{PASS} || $pf->{FAIL}) {
                    my $Xele = sprintf "eq_%s",
                        (
                         $normalize_value{$variable} ?
                         $normalize_value{$variable}->($value) :
                         $value
                        );
                    push @X, $Xele unless $seen{$Xele}++;

                }
                if (
                    $pf->{PASS} xor $pf->{FAIL}
                   ) {
                    my $vl = 40;
                    substr($value,$vl) = "..." if length $value > 3+$vl;
                    my $poor_mans_freehand_estimation = 0;
                    if ($poor_mans_freehand_estimation) {
                        warn sprintf
                            (
                             "%4d %4d %-23s | %s\n",
                             $pf->{PASS},
                             $pf->{FAIL},
                             $variable,
                             $value,
                            );
                    }
                }
            }
        }
        warn "variable[$variable]keys[$keys]X[@X]\n" unless $Opt{quiet};
        next VAR unless @X > 1;
        my %regdata =
            (
             X => \@X,
             data => [],
            );
      RECORD: for my $rec (@{$V->{"==DATA=="}}) {
            my $y = $ycb->($rec);
            next RECORD unless defined $y;
            my %obs;
            $obs{Y} = $y;
            @obs{@X} = (0) x @X;
            $obs{const} = 1;
            for my $x (@X) {
                if ($x =~ /^eq_(.+)/) {
                    my $read_v = $1;
                    if (exists $rec->{$variable}
                        && defined $rec->{$variable}
                       ) {
                        my $use_v = (
                                     $normalize_value{$variable} ?
                                     $normalize_value{$variable}->($rec->{$variable}) :
                                     $rec->{$variable}
                                    );
                        if ($use_v eq $read_v) {
                            $obs{$x} = 1;
                        }
                    }
                    # warn "DEBUG: y[$y]x[$x]obs[$obs{$x}]\n";
                } elsif ($x =~ /^n_(.+)/) {
                    my $v = $1;
                    $obs{$x} = eval { $normalize_numeric{$v}->($rec->{$v}); };
                    if ($@) {
                        warn "Warning: error during parsing v[$v] in record[$rec->{id}]: $@; continuing with undef value";
                    }
                }
            }
            push @{$regdata{data}}, \%obs;
        }
        _run_regression ($variable, \%regdata, \@regression, \%Opt);
    }
    my $top = min ($Opt{solvetop} || 3, scalar @regression);
    my $max_rsq = sum map {1==$_->rsq ? 1 : 0} @regression;
    $top = $max_rsq if $max_rsq && $max_rsq > $top;
    my $score = 0;
    printf
        (
         "State after regression testing: %d results, showing top %d\n\n",
         scalar @regression,
         $top,
        );
    for my $reg (sort {
                     $b->rsq <=> $a->rsq
                     ||
                     $a->k <=> $b->k
                 } @regression) {
        printf "(%d)\n", ++$score;
        eval { $reg->print; };
        if ($@) {
            printf "\n\nOops, Statistics::Regression died during ->print() with error message[$@]\n\n";
        }
        last if --$top <= 0;
    }
}
}

# $variable is the name we pass through to S:R constructor
# $regdata is hash and has the arrays "X" and "data" (observations)
# X goes to S:R constructor
# each observation has a Y which we pass to S:R in an include() call
# $regression is the collector array of results
# $opt are the options from outside, used to see if we are "verbose"
sub _run_regression {
    my($variable,$regdata,$regression,$opt) = @_;
    my @X = @{$regdata->{X}};
    # my $splo = $regdata->{"spliced-out"} = []; # maybe can be used to
                                               # hold the reference
                                               # group
    while (@X > 1) {
        my $reg = Statistics::Regression->new($variable,\@X);
        for my $obs (@{$regdata->{data}}) {
            my $y = delete $obs->{Y};
            $reg->include($y, $obs);
            $obs->{Y} = $y;
        }
        eval {$reg->theta;
              my @e = $reg->standarderrors;
              die "found standarderrors == 0" if grep { 0 == $_ } @e;
              $reg->rsq;};
        if ($@) {
            if ($opt->{verbose} && $opt->{verbose}>=2) {
                require YAML::Syck;
                warn YAML::Syck::Dump
                    ({error=>"could not determine some regression parameters",
                      variable=>$variable,
                      k=>$reg->k,
                      n=>$reg->n,
                      X=>$regdata->{"X"},
                      errorstr => $@,
                     });
            }
            # reduce k in case that linear dependencies disturbed us;
            # often called reference group; I'm tempted to collect and
            # make visible
            splice @X, 1, 1;
        } else {
            # $reg->print;
            push @$regression, $reg;
            return;
        }
    }
}

=head1 AUTHOR

Andreas König

=head1 BUGS

Please report any bugs or feature requests through the web
interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=CPAN-Testers-ParseReport>.
I will be notified, and then you'll automatically be notified of
progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc CPAN::Testers::ParseReport


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=CPAN-Testers-ParseReport>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/CPAN-Testers-ParseReport>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/CPAN-Testers-ParseReport>

=item * Search CPAN

L<http://search.cpan.org/dist/CPAN-Testers-ParseReport>

=back


=head1 ACKNOWLEDGEMENTS

Thanks to RJBS for module-starter.

=head1 COPYRIGHT & LICENSE

Copyright 2008 Andreas König.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

1; # End of CPAN::Testers::ParseReport
