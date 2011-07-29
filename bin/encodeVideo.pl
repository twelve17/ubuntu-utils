#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;
use Getopt::Long;

my $p = new Getopt::Long::Parser;
$p->configure();
my ($reuseFiles, $dryRun, $inputFile, $bitRate);
my $preset = 'hq';

my $result = $p->getoptions(
    "r|reuse-files" => \$reuseFiles,
    "d|dry-run" => \$dryRun,
    "i|input-file=s" => \$inputFile,
    "p|preset=s" => \$preset,
    "b|bitrate=s" => \$bitRate,
);

if ($result) {
    my $enc = new Video::Encode(dryRun => $dryRun, reuseIntermediaryFiles => $reuseFiles);
    $enc->encodeFile(presetName => $preset, inputFile => $inputFile, bitRate => $bitRate);
    #print Dumper($enc);
}

#=============================================================================
# Notes:
# Video file MUST end in .264 so that MP4Box recognizes it as a H264 raw file.
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
            mencoder => "/usr/local/bin/mencoder",
            ffmpeg => "/usr/bin/ffmpeg",
            #mp4box => "/usr/bin/MP4Box",
            mp4box => "/usr/local/bin/MP4Box",
            mplayer => "/usr/local/bin/mplayer",
            normalize => "/usr/bin/normalize-audio",
            faac => "/usr/bin/faac",
            neroAacEnc => "$ENV{HOME}/bin/nero/linux/neroAacEnc",
            # installed from source
            x264 => "/usr/local/bin/x264"
        },
    );

    $s->{workDir} = $args{workDir} || $ENV{PWD};

    $s->{progs} = $programs{$s->getPlatform()} || die "could not determine platform";

    $s->{inputFileExtensions} = qr/\.([Aa][Vv][Ii]|[Mm][Pp][Gg]|[Mm][Pp][Ee][Gg]|[Dd][Vv]|[Ff][Ll][Vv])$/;

    # TODO: externalize config
    $s->{presets} = {
        hq1 => {
            desc => 'High Quality: Full Size, Deinterlaced, AAC Audio.  MPlayer extracts and encodes video.  MPlayer extract audio, neroEnc encodes audo.',
            extractVideo => {
                prog => 'mplayer',
                fork => 1,
                files => {
                    log => '.264.extract.log',
                    fifo => '.264.fifo',
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
                    '-vf pp=md,harddup', #
                    '-nosound',
                    '-benchmark',
                    '-vo yuv4mpeg:file=@FIFO_FILE@',
                    '-really-quiet',
                    # output video to stdout...
                    #'-o -', 
                    # ...but log details to log file
                    '2> @LOG_FILE@',
                    # pipe to encoder
                    #'| @ENCODE_COMMAND@'
                ],
            },
            encodeVideo => {
                prog => 'x264',
                files => {
                    fifo => '.264.fifo',
                    input => undef,
                    log => undef,
                    output => '.264',
                },
                args => [
                    # expect raw input
                    '--demuxer y4m',
                    # Quality-based VBR (0-51, 0=lossless) [23.0]
                    '--crf 20',
                    '--threads auto',
                    #'--fps @FPS@',
                    '--input-res @RESOLUTION@',
                    '--output @OUTPUT_FILE@',
                    # read from encoder
                    '@FIFO_FILE@'
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
                    # (mplayer's 'file' option does not have stdout "-" option)
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
                    # read from extractor
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
        },
    };

    $s->{presets}->{hq2} = {
            desc => 'High Quality: Full Size, Deinterlaced, AAC Audio',
            encodeVideo => {
                prog => 'mencoder',
                files => {
                    log => '.264.encode.log',
                    output => '.264',
                },
                args => {
                    pass1 => [
                        '-of rawvideo',
                        '-ovc x264',
                        # http://www.mplayerhq.hu/DOCS/HTML/en/menc-feat-x264.html
                        '-x264encopts subq=1:frameref=1:pass=1:crf=20',
                        '-nosound',
                        '-o @OUTPUT_FILE@',
                        '@INPUT_FILE@'
                    ],
                    pass2 => [
                        #'-vf scale,pp=md,harddup',
                        #'-vf yadif',
                        '-of rawvideo',
                        '-ovc x264',
                        '-x264encopts subq=5:8x8dct:frameref=2:bframes=3:b_pyramid=normal:weight_b:pass=2:bitrate=@BITRATE@:vbv-maxrate=@MAX_BITRATE@:vbv_bufsize=@BITRATE_AVG_PERIOD_BUF_SIZE@',
                        # fast
                        #'-x264encopts subq=4:bframes=2:b_pyramid=normal:weight_b',
                        '-nosound',
                        '-o @OUTPUT_FILE@',
                        '@INPUT_FILE@'
                    ],
                }
            },
            extractAudio => $s->{presets}->{hq1}->{extractAudio},
            encodeAudio => $s->{presets}->{hq1}->{encodeAudio},
            mux => $s->{presets}->{hq1}->{mux},
    };
}

#-----------------------------------------------------------------------------
sub determineBitRates {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(videoInfo) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

    my %ret = (
        bitRate => undef,
        maxBitRate => undef,
        bitRateAvgPeriodBufSize => undef,
    );

    if (defined $args{bitRate}) {

        $ret->{bitRate} = ($args{bitRate} eq 'source' ? ($args{videoInfo}->{VIDEO_BITRATE} / 1000) : $args{bitRate});
        $ret->{maxBitRate} = $args{maxBitRate} || $ret->{bitRate};
        $ret->{bitRateAvgPeriodBufSize} = $ref->{bitRate} * 2;

        print "using bitrate: $bitRate, max: $maxBitRate, bufSize: $bitRateAvgPeriodBufSize\n";

        while (my ($type,$value) = each (%ret)) {
            if ($value =~ /^(\d+)\.(\d*)$/) {
                my $new = $1;
                print "found decimal places in bitrate.  truncating value ($value -> $new), as x264 won't accept fractional bitrates"
                $ret->{$type} = $new;
            }
        }
    }
    else {
        print "no bitrate specified.  this will cause a failure if this preset uses 2-pass encoding\n";
    }

    return \%ret;
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
    print "videoInfo:\n" . Dumper($videoInfo);

    print "workDir: $s->{workDir}\n";
    chdir $s->{workDir} || die "could not cd to '$s->{workDir}': $!";

    my $fps = $videoInfo->{VIDEO_FPS};
    my $resolution = ($videoInfo->{VIDEO_WIDTH} . 'x' . $videoInfo->{VIDEO_HEIGHT});
    my $rates = $s->determineBitRates(%args, videoInfo => $videoInfo);

    $s->encodeVideoTrack(
        preset => $preset, 
        inputFile => $args{inputFile}, 
        fps => $fps,
        resolution => $resolution,
        width => $videoInfo->{VIDEO_WIDTH},
        height => $videoInfo->{VIDEO_HEIGHT},
        bitRate => $rates->{bitRate},
        maxBitRate => $rates->{maxBitRate},
        bitRateAvgPeriodBufSize => $rates->{bitRateAvgPeriodBufSize},
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

    $s->_encodeTrack(
        type => 'video',
        inputFile => $args{inputFile},
        extractTask => $args{preset}->{extractVideo},
        extractTokens => {
            FPS => $args{fps},
        },
        encodeTask => $args{preset}->{encodeVideo},
        encodeTokens => {
            FPS => $args{fps},
            RESOLUTION => $args{resolution},
            BITRATE => $args{bitRate},
            MAX_BITRATE => $args{maxBitRate},
            BITRATE_AVG_PERIOD_BUF_SIZE => $args{bitRateAvgPeriodBufSize},
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

    $s->_encodeTrack(
        type => 'audio',
        inputFile => $args{inputFile},
        extractTask => $args{preset}->{extractAudio},
        encodeTask => $args{preset}->{encodeAudio},
    );
}

#-----------------------------------------------------------------------------
sub _encodeTrack {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(inputFile encodeTask type) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

    if ($s->isReusingFile(file => $args{encodeTask}->{files}->{output})) {
        return;
    }

    print "encoding $args{type} track from input: $args{inputFile}\n";

    if (defined ($args{extractTask})) {
        $s->doExtractWithEncodeCommands(
            extractTask => $args{extractTask},
            extractTokens => $args{extractTokens},
            encodeTask  => $args{encodeTask},
            encodeTokens  => $args{encodeTokens},
        );
    }
    else {
        $s->doCommandBatch(
            prog => $args{encodeTask}->{prog}, 
            args => $args{encodeTask}->{args}, 
            tokens => $args{encodeTokens},
        );
    }
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

    $s->doCommandBatch(
        prog => $args{preset}->{mux}->{prog}, 
        args => $args{preset}->{mux}->{args}, 
        tokens => {
            AUDIO_INPUT_FILE => $args{preset}->{encodeAudio}->{files}->{output},
            VIDEO_INPUT_FILE => $args{preset}->{encodeVideo}->{files}->{output},
            FPS => $args{fps},
        }
    );
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

    if ($s->isReusingFile(file => $args{encodeTask}->{files}->{output})) {
        return;
    }

    # named pipe & forking approach
    if ($args{extractTask}->{fork}) {

        print "forking extraction\n";

        my $pid = fork();
        # parent
        if ($pid) {
            print "extract pid = $pid, parent = $$\n";
            push(@{$s->{childPids}}, $pid);
   
            sleep(4);
 
            $s->doCommandBatch(
                prog => $args{encodeTask}->{prog}, 
                args => $args{encodeTask}->{args}, 
                tokens => $args{encodeTokens}
            ); 
    
            my $tmp = waitpid($pid, 0);
            print "pid $pid finished\n";
        }
        # child
        elsif ($pid == 0) {
            $s->doCommandBatch(
                prog => $args{extractTask}->{prog}, 
                args => $args{extractTask}->{args}, 
                tokens => $args{extractTokens}
            ); 
            exit(0);
        }
        else {
            die "couldn't fork: $!";
        }
    }
    # pipe approach
    else {
        my $encodeCommand =  $s->getCommandWithArgs(
            prog => $args{encodeTask}->{prog}, 
            args => $args{encodeTask}->{args}, 
            tokens => $args{encodeTokens}
        ); 
    
        if (defined $args{extractTokens}) {
            $args{extractTokens}->{ENCODE_COMMAND} = $encodeCommand;
        }
        else {
            $args{extractTokens} = { ENCODE_COMMAND => $encodeCommand };
        }
    
        $s->doCommandBatch(
            prog => $args{extractTask}->{prog}, 
            args => $args{extractTask}->{args}, 
            tokens => $args{encodeTokens}
        ); 
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
        my $output = $result->{output};
        $output =~ s/$key=//;
        return $output;
    }
    else {
        my %info;
        my $result = $s->runProg(name => "mplayer", args => $opts, showOutput => 0, dryRun => 0);
        #print "result:" . Dumper($result);
        foreach my $line(split(/\n/, $result->{output})) {
            next if ($line !~ /=/ || $line !~ /^ID_/);
            my ($k,$v) = split('=', $line);
            $k =~ s/^ID_//g;
            $info{$k} = $v;
        }
        return \%info;
    }
}

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

        if (ref($ref->{args}) eq 'HASH') {
            while (my ($batchName, $batchArgs) = each(%{$ref->{args}})) {
                $s->fillTokens(args => $batchArgs, tokens => \%tokens);
            }
        }
        else {
            $s->fillTokens(args => $ref->{args}, tokens => \%tokens);
        }
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

    my $loop = $args{args};
    if (ref($loop) eq 'HASH') {
        while (my ($ref) = values(%{$loop})) {
        }
    }
    else {
        foreach my $arg (@{$args{args}}) {
            while (my($k,$v) = each %{$args{tokens}}) {
                my $token = '@' . $k . '@';
                if ($arg =~ /$token/) {
                   $arg =~ s/$token/$v/g;
                } 
            } 
        }
    }
}

#-----------------------------------------------------------------------------
sub isReusingFile {
    my $s = shift;
    my %args = @_;

    if ($s->{reuseIntermediaryFiles}) {
        my $destFile = $s->{workDir} . '/' . $args{file};
        if (-f $destFile) {
            print "encoded file '$destFile' already exists. using it.\n";
            return 1;
        }
    }

    return 0;
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
    foreach my $k qw(prog args) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }
   
    my $command = $s->getProgPath($args{prog});
    if (defined $args{args}) {
        if (ref($args{args}) eq 'ARRAY') {
            my $parsedArgs= $s->getCommandArgs(args => $args{args}, tokens => $args{tokens}); 
            $command .= " " . $parsedArgs;
        }
        else {
            $command .= " " . $args{args};
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
sub doCommandBatch {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(prog args) {
        if (! defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

    print "args (" . ref($args{args})  . "):\n", Dumper(\%args);

    if (ref($args{args}) eq 'HASH') {
        while (my($batchName, $batchArgs) = each %{$args{args}}) {
            print "doing command batch '$batchName'\n";
            my $command = $s->getCommandWithArgs(
                prog => $args{prog}, 
                args => $batchArgs, 
                tokens => $args{tokens}
            );
            $s->doCommand($command, 1, $s->{dryRun});
        }
    }    
    else {
        print "command is not a batch command.\n";
        my $command = $s->getCommandWithArgs(%args);
        $s->doCommand($command, 1, $s->{dryRun});
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
