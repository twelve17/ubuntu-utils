#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;
use Getopt::Long;

my $p = new Getopt::Long::Parser;

$p->configure();

my ($reuseFiles, $dryRun, $inputFile);
my $preset = 'hq';

my $result = $p->getoptions(
    "r|reuse-files" => \$reuseFiles,
    "d|dry-run" => \$dryRun,
    "i|input-file=s" => \$inputFile,
    "p|preset=s" => \$preset,
);

if ($result) {
    my $enc = new Video::Encode(dryRun => $dryRun, reuseIntermediaryFiles => $reuseFiles);
    $enc->encodeFile(presetName => $preset, inputFile => $inputFile);
    # encoded 31329 frames, 4.64 fps, 3619.98 kb/s
    #print Dumper($enc);
}

#=============================================================================

package Video::Encode;

use strict;
use warnings;

use Clone qw(clone);
use Data::Dumper;
use File::Basename qw(basename);
use POSIX qw(mkfifo);

#------------------------------------------------------------------------------
sub new {
    my $proto = shift;
    my $class = ref($proto) || $proto;
    my $s  = {};
    bless ($s, $class);
    $s->initialize(@_);
    return $s;
}

#------------------------------------------------------------------------------
sub initialize {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(dryRun reuseIntermediaryFiles normalizeAudio) {
        if (defined $args{$k}) {
            $s->{$k} = $args{$k};
        }
    }

    $s->{childPids} = [];

    my %programs = (
        mac => { 
            sox => "/opt/local/bin/sox",
            mencoder => "/opt/local/bin/mencoder",
            ffmpeg => "/opt/local/bin/ffmpeg",
            mp4box => "/opt/bin/mp4box",
            movtowav => "/opt/bin/movtowav",
            normalize => "/opt/bin/normalize",
            qaac_enc => "TODO: http://forum.doom9.org/showthread.php?s=a01d113d2907ffb5a2c00b0d0694a989&t=154233&page=2"
        },
        linux => {
            sox => "/usr/bin/sox",
            mencoder => "/usr/bin/mencoder",
            ffmpeg => "/usr/bin/ffmpeg",
            mp4box => "/usr/bin/MP4Box",
            mplayer => "/usr/bin/mplayer",
            normalize => "/usr/bin/normalize-audio",
            faac => "/usr/bin/faac",
            neroAacEnc => "$ENV{HOME}/bin/nero/linux/neroAacEnc",
            # installed from source
            x264 => "/usr/local/bin/x264"
        },
    );


    $s->{workDir} = $args{workDir} || $ENV{PWD};

    $s->{progs} = $programs{$s->getPlatform()} || die "could not determine platform";

    $s->{inputFileExtensions} = qr/\.([Aa][Vv][Ii]|[Mm][Pp][Gg]|[Mm][Pp][Ee][Gg]|[Dd][Vv])$/;

    #local mencoder_ovc_opts="-ovc x264 -x264encopts threads=2:me=umh:bitrate=$vbitrate:subq=6:partitions=all:8x8dct:frameref=5:bframes=3:b_pyramid:weight_b"
    #local mencoder_other_opts="-passlogfile $tmpdir/$pass_log_file -ofps $fps -vf pp=md,harddup -of rawvideo -nosound"
    #for num in 1 2; do
    #    "$MENCODER_BIN" "$in_video_file" ${mencoder_ovc_opts}:pass=${num} $mencoder_other_opts -o $tmpdir/$out_264_video_file
    #done

    $s->{presets} = {
        hq => {
            desc => 'High Quality: Full Size, Deinterlaced, AAC Audio',
            extractVideo => {
                prog => 'mencoder',
                files => {
                    log => '.m4v.extract.log',
                },
                args => [
                    '@INPUT_FILE@',
                    # output raw video
                    '-of rawvideo',
                    '-ofps @FPS@',
                    '-ovc raw',
                    # use video filters: "yet another deinterlacing filter", Motion compensating deinterlacer, output to raw i420 format
                    #'-vf yadif=3,mcdeint=2:1:10,format=i420',
                    #'-vf pp=md,harddup,format=i420', #
                    #'-vf yadif=1,format=i420', #
                    # we're dealing with video only. ignore sound.
                    '-nosound',
                    #'-really-quiet',
                    # output video to stdout...
                    '-o -', 
                    # ...but log details to log file
                    '2> @LOG_FILE@',
                    # pipe to encoder
                    '| @ENCODE_COMMAND@'
                ],
            },
            encodeVideo => {
                prog => 'x264',
                files => {
                    input => undef,
                    log => undef,
                    output => '.m4v',
                },
                args => [
                    # expect raw input
                    '--demuxer raw',
                    # Quality-based VBR (0-51, 0=lossless) [23.0]
                    '--crf 20',
                    '--threads auto',
                    '--fps @FPS@',
                    '--input-res @RESOLUTION@',
                    '--output @OUTPUT_FILE@',
                    # read stdin (from mencoder)
                    '-'
                ],
            },
            extractAudio => {
                prog => 'mplayer',
                fork => 1,
                files => {
                    log => '.m4a.extract.log',
                    fifo => '.m4a.fifo',
                },
                args => [
                    '-quiet',
                    '-nocorrect-pts',
                    '-vo null',
                    '-vc null',
                    # subshell to encoder (mplayer's 'file' option does not have stdout "-" option)
                    '-ao pcm:fast:file=@FIFO_FILE@',
                   '@INPUT_FILE@',
                   '2>&1 > @LOG_FILE@'
                ],
            },
            encodeAudio => {
                prog => 'neroAacEnc',
                files => {
                    log => '.m4a.encode.log',
                    fifo => '.m4a.fifo',
                    output => '.m4a',
                },
                args => [
                    '-ignorelength',
                    # "use LC AAC profile (supported by most devices)"
                    '-lc',
                    # target quality mode (vbr),
                    '-q 0.6',
                    # read from stdin
                    '-if @FIFO_FILE@',
                    '-of @OUTPUT_FILE@',
                    # log details to separate log file
                    '2> @LOG_FILE@'
                ],
            },
            mux => {
                prog => 'mp4box',
                files => { output => '.mp4' },
                args => [
                    '-fps @FPS@',
                    '-add @VIDEO_INPUT_FILE@',
                    '-add @AUDIO_INPUT_FILE@',
                    '@OUTPUT_FILE@'
                ],
            }
        }
    };
}

#-----------------------------------------------------------------------------
sub runProg {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(name) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

   my $command = $s->getProgPath($args{name});
   if ($args{args}) {
       $command .= ' ' . $args{args};
   }
   $s->doCommand($command, $args{showOutput}, $args{dryRun});
}
 
#-----------------------------------------------------------------------------
sub getCommandWithArgs {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(taskref) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }
   
    my $command = $s->getProgPath($args{taskref}->{prog});
    if (defined $args{taskref}->{args}) {
        if (ref($args{taskref}->{args}) eq 'ARRAY') {
            my $parsedArgs= $s->getCommandArgs(args => $args{taskref}->{args}, tokens => $args{tokens}); 
            $command .= " " . $parsedArgs;
        }
        else {
            $command .= " " . $args{taskref}->{args};
        }
    }

    return $command;
}

#-----------------------------------------------------------------------------
sub getCommandArgs {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(args) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

    my @tokenized;

    foreach my $arg(@{$args{args}}) {  # AAARRRRGSSS MATEY!
        while ($arg =~ /(@)([^@]+)(@)/) {
           my $token = $2;
           #print "found token: $token\n";
           if (! defined($args{tokens})) {
               die "tokens not defined. cannot resolve token '$token'";
           }
           else {
               my $value = $args{tokens}->{$token} || die "value for token '$token' not found";
               $arg =~ s/$1$2$3/$value/;  
               #print "arg is now: $arg\n";
           } 
        }

        push(@tokenized, $arg);
    }

    return join(" ", @tokenized);
}

#-----------------------------------------------------------------------------
sub getProgPath {
    my $s = shift;
    my $name = shift || die "no name";
    if (defined $s->{progs}->{$name}) {
        return $s->{progs}->{$name};
    }
    else {
        die "path for program '$name' not found";
    }
}

#-----------------------------------------------------------------------------
sub getPlatform {
    my $s = shift;
    my $ret = $s->doCommand("uname", 0, 0);
    if ($ret->{output} eq "Darwin") {
        print "Mac OS Detected\n";
        return "mac";
    }
    else {
        print "Linux OS Detected\n";
        return "linux";  
    } 
}

#-----------------------------------------------------------------------------
sub getVideoInfo {
    my $s = shift;
    my $file = shift || die "no file";
    my $key = shift;


    # http://lists.mplayerhq.hu/pipermail/mplayer-users/2007-March/066366.html
    my $opts = "-identify -vo null -frames 0 $file";

    if ($key) {
        my $result = $s->runProg(name => "mplayer", args => "$opts | grep $key", showOutput => 0, dryRun => 0);
        #print "result with key:" . Dumper($result);
        my $output = $result->{output};
        $output =~ s/$key=//;
        return $output;
    }
    else {
        my %info;
        my $result = $s->runProg(name => "mplayer", args => $opts, showOutput => 0, dryRun => 0);
        #print "result:" . Dumper($result);
        foreach my $line(split(/\n/, $result->{output})) {
            #print "line=$line\n";
            next if ($line !~ /=/ || $line !~ /^ID_/);
            my ($k,$v) = split('=', $line);
            $k =~ s/^ID_//g;
            $info{$k} = $v;
        }
        return \%info;
    }
}


#-----------------------------------------------------------------------------
# 
#-----------------------------------------------------------------------------
sub resolvePreset {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(name inputFile) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

    my $tmp = $s->{presets}->{$args{name}} || die "could not find preset '$args{name}'\n";
    # we're gonna change up some values, so let's work on a copy
    my %preset = %{ clone($tmp) };

    my $baseName = basename($args{inputFile});

    # resolve file paths
    while (my ($task, $ref) = each %preset) {
        next if (ref($ref) ne 'HASH' || ! defined $ref->{prog});

        my %tokens = (INPUT_FILE => $args{inputFile});

        if (defined $ref->{files}) {

            my $files = $ref->{files};

            # could not get basename(file, regexp) to work, so we'll do it ourselves
            $baseName =~ s/$s->{inputFileExtensions}//;

            foreach my $type qw(log output fifo) {
                if (defined $files->{$type}) {
                    my $fileName = $baseName . $files->{$type}; 
                    $ref->{files}->{$type} = $fileName;

                    my $token = uc($type) . '_FILE';
                    $tokens{$token} = $fileName;

                    if ($type eq 'fifo') {
                        my $fullPath = $s->{workDir} . '/' . $ref->{files}->{fifo};
                        print "fifo path is: $fullPath\n";
                        if (! -p $fullPath) {
                            mkfifo($fullPath, 0700) || die "could not mkfifo path '$fullPath': $!";
                        }
                    }
                } 
            } 

        } 

        $s->fillTokens(args => $ref->{args}, tokens => \%tokens);
    }
    
    print "preset:\n", Dumper(\%preset);

    return \%preset;
}

#-----------------------------------------------------------------------------
sub fillTokens {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(args tokens) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

    foreach my $arg (@{$args{args}}) {
        while (my($k,$v) = each %{$args{tokens}}) {
            my $token = '@' . $k . '@';
            if ($arg =~ /$token/) {
               $arg =~ s/$token/$v/g;
            } 
        } 
    }
}

#-----------------------------------------------------------------------------
# big daddy
#-----------------------------------------------------------------------------
sub encodeFile {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(presetName inputFile) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }
 
    my $preset = $s->resolvePreset(name => $args{presetName}, inputFile => $args{inputFile});

    my $videoInfo = $s->getVideoInfo($args{inputFile});
    print "Info:\n" . Dumper($videoInfo);

    print "workDir: $s->{workDir}\n";
    chdir $s->{workDir} || die "could not cd to '$s->{workDir}': $!";

    my $fps = $videoInfo->{VIDEO_FPS};
    my $resolution = ($videoInfo->{VIDEO_WIDTH} . 'x' . $videoInfo->{VIDEO_HEIGHT});

    $s->encodeVideoTrack(
        preset => $preset, 
        inputFile => $args{inputFile}, 
        fps => $fps,
        resolution => $resolution,
    );

    $s->encodeAudioTrack(
        preset => $preset, 
        inputFile => $args{inputFile}, 
    );

    $s->muxTracks(
        preset => $preset, 
        fps => $fps,
    );
}

#-----------------------------------------------------------------------------
sub encodeVideoTrack {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(preset inputFile fps resolution) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

    $s->doExtractWithEncodeCommands(
        extractTask => $args{preset}->{extractVideo},
        extractTokens => {
            FPS => $args{fps},
        },
        encodeTask  => $args{preset}->{encodeVideo},
        encodeTokens => {
            FPS => $args{fps},
            RESOLUTION => $args{resolution},
        },
    );

}

#-----------------------------------------------------------------------------
sub encodeAudioTrack {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(preset inputFile) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

    $s->doExtractWithEncodeCommands(
        extractTask => $args{preset}->{extractAudio},
        encodeTask  => $args{preset}->{encodeAudio},
    );
}

#-----------------------------------------------------------------------------
sub muxTracks {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(preset fps) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

    my $muxCommand =  $s->getCommandWithArgs(taskref => $args{preset}->{mux}, tokens => {
            AUDIO_INPUT_FILE => $args{preset}->{encodeAudio}->{files}->{output},
            VIDEO_INPUT_FILE => $args{preset}->{encodeVideo}->{files}->{output},
            FPS => $args{fps},
        }
    );

    $s->doCommand($muxCommand);
}

#-----------------------------------------------------------------------------
sub doExtractWithEncodeCommands {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(extractTask encodeTask) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

    if ($s->{reuseIntermediaryFiles}) {
        my $destFile = $s->{workDir} . '/' . $args{encodeTask}->{files}->{output};
        print "destFile: $destFile\n";
        if (-f $destFile) {
            print "encoded file '$destFile' already exists. using it.\n";
            return;
        }
    }

    if ($args{extractTask}->{fork}) {

        print "forking extraction\n";

        my $pid = fork();
        # parent
        if ($pid) {
            print "extract pid = $pid, parent = $$\n";
            push(@{$s->{childPids}}, $pid);
   
            sleep(4);
 
            my $encodeCommand =  $s->getCommandWithArgs(taskref => $args{encodeTask}, tokens => $args{encodeTokens}); 
            $s->doCommand($encodeCommand);
    
            my $tmp = waitpid($pid, 0);
            print "pid $pid finished\n";
        }
        # child
        elsif ($pid == 0) {
            my $extractCommand = $s->getCommandWithArgs(taskref => $args{extractTask}, tokens => $args{extractTokens});
            $s->doCommand($extractCommand);
            exit(0);
        }
        else {
            die "couldn't fork: $!";
        }
    }
    else {
        my $encodeCommand =  $s->getCommandWithArgs(taskref => $args{encodeTask}, tokens => $args{encodeTokens}); 
    
        if (defined $args{extractTokens}) {
            $args{extractTokens}->{ENCODE_COMMAND} = $encodeCommand;
        }
        else {
            $args{extractTokens} = { ENCODE_COMMAND => $encodeCommand };
        }
    
        my $extractCommand = $s->getCommandWithArgs(taskref => $args{extractTask}, tokens => $args{extractTokens});
    
        $s->doCommand($extractCommand, 1, $s->{dryRun}, 1);
    }
}

#-----------------------------------------------------------------------------
sub doForkedExtractWithEncodeCommands {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(extractTask encodeTask) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }



}
#-----------------------------------------------------------------------------
sub doCommand {
    my $s = shift;
    my $cmd = shift || die "no key";

    my $showOutput = shift;
    if (! defined $showOutput) {
        $showOutput = 1;
    }

    my $dryRun = shift;
    if (! defined $dryRun) {
        $dryRun = $s->{dryRun};
    }

    my %stats;

    if ($dryRun) {
        print "command (dry run): $cmd\n";
        return { rc => 0, output => "" };
    }
    else { 
        print "doing command (output=$showOutput): $cmd\n";

        $stats{pid} = CORE::open(PH, "$cmd 2>&1 |") || die "error running command '$cmd': $!";
            while (my $tmp = <PH>) {
                if($showOutput) {
                    print $tmp; # print the command as it runs so we aren't clueless until it's done
                }
                $stats{output} .= $tmp;
            }
        CORE::close(PH) || die "command pipe close() had errors for command '$cmd'";
    
        $stats{rc} =  ($? >> 8);  # from perlvar man page (search for $?):
                                  # $? >> 8 returns the real return code

        if ($stats{rc} > 0) {
            die "non-zeror return code from command: $cmd";
        } 
        return \%stats;
    }
}

1;
