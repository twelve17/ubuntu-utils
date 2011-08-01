#!/usr/bin/perl

use strict;
use warnings;

use Data::Dumper;
use Getopt::Long;

my $p = new Getopt::Long::Parser;
$p->configure();
my ($reuseFiles, $dryRun, $inputFile, $bitRate);
my $preset = 'hq1';

my $result = $p->getoptions(
    "r|reuse-files" => \$reuseFiles,
    "d|dry-run" => \$dryRun,
    "i|input-file=s" => \$inputFile,
    "p|preset=s" => \$preset,
    "b|bitrate=s" => \$bitRate,
);

if ($result) {
    my $enc = new Video::Encode(dryRun => $dryRun, reuseIntermediaryFiles => $reuseFiles);
    $SIG{INT} = sub { $enc->handleInt() };
    $SIG{__DIE__} = sub { $enc->cleanUp(1, shift) };
    $enc->encodeFile(presetName => $preset, inputFile => $inputFile, bitRate => $bitRate);
    #print Dumper($enc);
}

#=============================================================================
# Notes:
# Video file MUST end in .264 so that MP4Box recognizes it as a H264 raw file.
# TODO: cleanup fifo/tmp files when done
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
    $s->{workDir} = $args{workDir} || $ENV{PWD};
    $s->{inputFileExtensions} = qr/\.([Aa][Vv][Ii]|[Mm][Pp][Gg]|[Mm][Pp][Ee][Gg]|[Dd][Vv]|[Ff][Ll][Vv])$/;

    my %programs = (
        mac => { 
            sox => { 
                path => "/opt/local/bin/sox",
            },
            mencoder => { 
                path => "/opt/local/bin/mencoder",
            },
            ffmpeg => { 
                path => "/opt/local/bin/ffmpeg",
            },
            mp4box => { 
                path => "/opt/bin/mp4box",
            },
            movtowav => { 
                path => "/opt/bin/movtowav",
            },
            normalize => { 
                path => "/opt/bin/normalize",
            },
            qaac_enc => { 
                path => "TODO: http://forum.doom9.org/showthread.php?s=a01d113d2907ffb5a2c00b0d0694a989&t=154233&page=2"
        },
            },
        linux => {
            sox => { 
                path => "/usr/bin/sox",
            },
            mencoder => { 
                path => "/usr/local/bin/mencoder",
                tokens => {
                    # use video filters: "yet another deinterlacing filter", Motion compensating deinterlacer
                    YADIF_AND_MOTION_DEINTERLACER => 'yadif=3,mcdeint=2:1:10',

                    # harddup: "This uses slightly more space, but is necessary for output to MPEG files or if you plan to demux and remux the video stream after  encoding."
                    MEDIAN_DEINTERLACER_AND_FRAME_DUPLICATION => 'pp=md,harddup', 

                    # http://www.mplayerhq.hu/DOCS/tech/colorspaces.txt
                    # this seems to be the common colorspace used in h264, although it is possible to use higher
                    # quality color spaces:
                    # http://en.wikipedia.org/wiki/YUV_4:2:2#4:2:0
                    RAW_VIDEO_I420_FORMAT => 'format=i420',
                    
                    RAW_EXTRACT => [
                        '-of rawvideo',
                        '-ofps @FPS@',
                        '-nosound',
                        '-benchmark',
                        '-ovc raw',
                   ],

                   X264_ENCODE_COMMON => [
                        '-nosound',
                        '-of rawvideo',
                        '-ovc x264',
                   ],

                   # http://www.mplayerhq.hu/DOCS/HTML/en/menc-feat-x264.html
                   # subq & frameref: lower # = faster, use low # for 1st pass to increase its speed. 
                   # crf: constant quality mode (crf=20)
                   X264_ENCODE_PASS1_COMMON => 'subq=1:frameref=1:pass=1',

                   X264_ENCODE_PASS2_COMMON => 'subq=5:8x8dct:frameref=2:bframes=3:b_pyramid=normal:weight_b',

                   # http://sites.google.com/site/linuxencoding/x264-encoding-guide 
                   X264_ENCODE_PASS_2_IPHONE_IPOD5_5G => '@X264_ENCODE_COMMON@ -x264encopts @X264_ENCODE_PASS2_COMMON@:level_idc=30:vbv-maxrate=10000:vbv_bufsize=10000',
                   X264_ENCODE_PASS_2_IPHONE_IPOD => '@X264_ENCODE_COMMON@ -x264encopts @X264_ENCODE_PASS2_COMMON@:level_idc=1.3:nocabac:vbv-maxrate=768:vbv_bufsize=768',

                   X264_ENCODE_PASS_1 => '@X264_ENCODE_COMMON@ -x264encopts @X264_ENCODE_PASS1_COMMON@',
                   X264_ENCODE_PASS_2 => '@X264_ENCODE_COMMON@ -x264encopts @X264_ENCODE_PASS2_COMMON@:pass=2:bitrate=@BITRATE@:vbv-maxrate=@MAX_BITRATE@:vbv_bufsize=@BITRATE_AVG_PERIOD_BUF_SIZE@',
                }
            },
            ffmpeg => { 
                path => "/usr/bin/ffmpeg",
            },
            mp4box => { 
                path => "/usr/local/bin/MP4Box",
            },
            mplayer => { 
                path => "/usr/local/bin/mplayer",
                tokens => {
                    RAW_EXTRACT => [
                        '-quiet',
                        '-nocorrect-pts',
                        '-benchmark',
                        '-vc null',
                        '-vo null',
                        # (mplayer's 'file' option does not have stdout "-" option)
                        '-ao pcm:fast:file=@FIFO_FILE@',
                   ],
               },
            },
            normalize => { 
                path => "/usr/bin/normalize-audio",
            },
            faac => { 
                path => "/usr/bin/faac",
            },
            neroAacEnc => { 
                path => "$ENV{HOME}/bin/nero/linux/neroAacEnc",
            },
            # installed from source
            x264 => { 
                path => "/usr/local/bin/x264"
        },
            },
    );

    $s->{cmd} = Command::Simple->new();
    $s->{progs} = $programs{$s->getPlatform()} || die "could not determine platform";
    $s->{videoInfo} = Video::Info->new(mplayerPath => $s->getProgPath('mplayer'));

    $s->{taskDefaults} = {
        extractVideo => {
            outputFileSuffix => '.rawvideo',
            progOutputPrefix => 'EXTRACT_VIDEO',
        },
        encodeVideo => {
            outputFileSuffix => '.264',
            progOutputPrefix => 'ENCODE_VIDEO',
        },
        extractAudio => {
            outputFileSuffix => '.rawaudio',
            progOutputPrefix => 'EXTRACT_AUDIO',
        },
        encodeAudio => {
            outputFileSuffix => '.m4a',
            progOutputPrefix => 'ENCODE_AUDIO',
        },
        mux => {
            outputFileSuffix => '.mp4',
            progOutputPrefix => 'MUX_TRACKS',
        },
    };

    # TODO: externalize config
    $s->{presets} = {
        hq1 => {
            desc => 'Same as hq1, except no deinterlacing and mencoder does extraction and encoding.',
            encodeVideo => {
                prog => 'mencoder',
                args => {
                    pass1 => [
                        '@X264_ENCODE_PASS_1@',
                        '-o @OUTPUT_FILE@',
                        '@INPUT_FILE@'
                    ],
                    pass2 => [
                        '@X264_ENCODE_PASS_2@',
                        '-o @OUTPUT_FILE@',
                        '@INPUT_FILE@'
                    ],
                }
            },
            extractAudio => {
                prog => 'mplayer',
                fork => 1,
                args => [
                    '@RAW_EXTRACT@',
                    '@INPUT_FILE@',
                ],
            },
            encodeAudio => {
                prog => 'neroAacEnc',
                args => [
                    '-ignorelength',
                    # "use LC AAC profile (supported by most devices)"
                    '-lc',
                    # target quality mode (vbr),
                    '-q 0.6',
                    # read from extractor
                    '-if @FIFO_FILE@',
                    '-of @OUTPUT_FILE@',
                ],
            },
            mux => {
                prog => 'mp4box',
                args => [
                    '-fps @FPS@',
                    '-add @VIDEO_INPUT_FILE@',
                    '-add @AUDIO_INPUT_FILE@',
                    '@OUTPUT_FILE@'
                ],
            },
        },
        hq2_beta => {
            desc => 'Full Size, Deinterlaced, AAC Audio.  MPlayer extracts and encodes video.  MPlayer extract audio, neroEnc encodes audio.',
            extractVideo => {
                prog => 'mplayer',
                fork => 1,
                args => [
                    '@INPUT_FILE@',
                    '-vf @MEDIAN_DEINTERLACER_AND_FRAME_DUPLICATION@',
                    '-vo yuv4mpeg:file=@FIFO_FILE@',
                ],
            },
            encodeVideo => {
                prog => 'x264',
                args => [
                    '--threads auto',
                    # expect raw input
                    '--demuxer y4m',
                    # Quality-based VBR (0-51, 0=lossless) [23.0]
                    '--crf 20',
                    #'--fps @FPS@',
                    '--input-res @RESOLUTION@',
                    '--output @OUTPUT_FILE@',
                    # read from encoder
                    '@FIFO_FILE@'
                ],
            },
            extractAudio => 'alias:hq1',
            encodeAudio => 'alias:hq1',
            mux => 'alias:hq1',
        },
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

        $ret{bitRate} = ($args{bitRate} eq 'source' ? ($args{videoInfo}->{VIDEO_BITRATE} / 1000) : $args{bitRate});
        $ret{maxBitRate} = $args{maxBitRate} || $ret{bitRate};
        $ret{bitRateAvgPeriodBufSize} = $ret{bitRate} * 2;

        print "using bitrate: $ret{bitRate}, max: $ret{maxBitRate}, bufSize: $ret{bitRateAvgPeriodBufSize}\n";

        while (my ($type,$value) = each (%ret)) {
            if ($value =~ /^(\d+)\.(\d*)$/) {
                my $new = $1;
                print "found decimal places in $type.  truncating value ($value -> $new), as x264 won't accept fractional values for bitrates\n";
                $ret{$type} = $new;
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

    my $videoInfo = $s->{videoInfo}->readVideoFile(file => $args{inputFile});
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

    my $outputFile = $s->{workDir} . '/' . $preset->{mux}->{files}->{output};
    my $outVideoInfo = $s->{videoInfo}->readVideoFile(file => $outputFile);

    print "-"x10, "Stats", "-"x10, "\n";
    print "In: $videoInfo->{SIZE_HUMAN} / $videoInfo->{VIDEO_BITRATE} kbps / $videoInfo->{BITRATE_HUMAN}/s\n";
    print "Out: $outVideoInfo->{SIZE_HUMAN} / $outVideoInfo->{VIDEO_BITRATE} kbps / $outVideoInfo->{BITRATE_HUMAN}/s)\n";

    $s->cleanUp();
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
            outputPrefix => $args{encodeTask}->{progOutputPrefix},
        );
    }
}

#-----------------------------------------------------------------------------
sub doCommand {
    my $s = shift;
    $s->{cmd}->doCommand(@_);
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

    if ($s->isReusingFile(file => $args{preset}->{mux}->{files}->{output})) {
        return;
    }

    $s->doCommandBatch(
        prog => $args{preset}->{mux}->{prog}, 
        args => $args{preset}->{mux}->{args}, 
        tokens => {
            AUDIO_INPUT_FILE => $args{preset}->{encodeAudio}->{files}->{output},
            VIDEO_INPUT_FILE => $args{preset}->{encodeVideo}->{files}->{output},
            FPS => $args{fps},
        },
        outputPrefix => $args{preset}->{mux}->{progOutputPrefix},
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
            $s->registerPid($pid);
   
            $s->doCommandBatch(
                prog => $args{encodeTask}->{prog}, 
                args => $args{encodeTask}->{args}, 
                tokens => $args{encodeTokens},
                outputPrefix => $args{encodeTask}->{progOutputPrefix},
            ); 
    
            my $tmp = waitpid($pid, 0);
            print "pid $pid finished\n";
        }
        # child
        elsif ($pid == 0) {
            sleep(4);
            $s->doCommandBatch(
                prog => $args{extractTask}->{prog}, 
                args => $args{extractTask}->{args}, 
                tokens => $args{extractTokens},
                outputPrefix => $args{extractTask}->{progOutputPrefix},
            ); 
            $s->cleanUp(0);
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
            tokens => $args{encodeTokens},
            outputPrefix => $args{encodeTask}->{progOutputPrefix},
        ); 
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

    my $tmp = $s->{presets}->{$args{name}} || die "could not find preset '$args{name}'";
    # we're gonna change up some values, so let's work on a copy
    my %preset = %{ clone($tmp) };

    my $baseName = basename($args{inputFile});

    # resolve file paths
    while (my ($task, $ref) = each %preset) {

        if ($ref =~ /^(alias:)(.+)$/) {
            print "task '$task' is an alias to same task in preset '$2'\n";
            if (defined $s->{presets}->{$2}) {
                $ref = \%{ clone ($s->{presets}->{$2}->{$task}) };
                $preset{$task} = $ref;
            }
            else {
                die "$task task alias '$1' does not exist";
            }
        }

        next if (ref($ref) ne 'HASH' || ! defined $ref->{prog});

        # 1. grab task defaults and merge to this task

        if (defined $s->{taskDefaults}->{$task}) {
            print "adding task defaults for '$task'\n";
            while (my ($k, $v) = each %{$s->{taskDefaults}->{$task}}) {
                if (defined $ref->{$k}) {
                    warn "overwriting preset setting '$k': $ref->{$k} -> $v\n";
                }
                $ref->{$k} = $v;
            } 
        }

        my %tokens = (INPUT_FILE => $args{inputFile});

        my $files = $ref->{files} = {};

        # could not get basename(file, regexp) to work, so we'll do it ourselves
        $baseName =~ s/$s->{inputFileExtensions}//;

        # 2. create built in file tokens

        if (defined $s->{taskDefaults}->{$task}) {
            foreach my $type qw(log output fifo) {

                my $token = uc($type) . '_FILE';

                my $outputFileSuffix = $ref->{outputFileSuffix};

                # kinda hack-y. if this is the encode task, use the FIFO name from its extract task, if there is one    
		if ($type eq 'fifo' && $task =~ /^encode(.+)/) {
                    my $extractRef = $s->{taskDefaults}->{'extract' . $1};
                    if (defined $extractRef && defined $extractRef->{outputFileSuffix}) {
                        print "encode task will use fifo extension from extract task: $extractRef->{outputFileSuffix}\n";
                        $outputFileSuffix = $extractRef->{outputFileSuffix};
                    }
                    else {
                        print "encode task will use its own fifo extension: $outputFileSuffix\n";
                    }
                }

                my $fileName = $baseName . $outputFileSuffix;
                if ($type ne 'output') {
                    $fileName .= '.' . $type; 
                }
                $files->{$type} = $fileName;
                $tokens{$token} = $fileName;
    
                if ($ref->{fork} && $type eq 'fifo') {
                    my $fullPath = $s->{workDir} . '/' . $fileName;
                    print "fifo path is: $fullPath\n";
                    if (! -p $fullPath && ! $s->{dryRun}) {
                        mkfifo($fullPath, 0700) || die "could not mkfifo path '$fullPath': $!";
                    }
                } 
            } 
        } 

        # 3. grab program level default tokens

        my $cmdConfig = $s->getProgConfig($ref->{prog});
        if (defined $cmdConfig->{tokens}) {
            print "injecting program default tokens\n";
            while (my($name,$value) = each %{$cmdConfig->{tokens}}) {
                if (ref($value) eq 'ARRAY') {
                    $tokens{$name} = join(' ', @{$value});
                }
                else { 
                    $tokens{$name} = $value;
                }
            }
        }

        #print "tokens now are (pre fill):", Dumper(\%tokens);

        # 4. resolve all tokens from above into this task's args

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

    foreach my $arg (@{$args{args}}) {
OUTER:      while (1) {
            my $found = 0;
            while (my($k,$v) = each %{$args{tokens}}) {
                my $token = '@' . $k . '@';
                if ($arg =~ /$token/) {
                   $found++;
                   my $tokenValue = $v;
                   #print "token=$k, value=$tokenValue, arg=$arg\n"; 
                   $arg =~ s/$token/$tokenValue/g;
                } 
            }
            if ($arg !~ /@/ || $found == 0) {
                last OUTER;
                sleep 2;
            }
            if ($found > 999) {
                die "potential endless loop";
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
            print "target file '$destFile' already exists. using it.\n";
            return 1;
        }
        else {
            print "target file '$destFile' does not exist.\n";
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

    my $allowMissingTokenValues = (defined $args{allowMissingTokenValues} ? $args{allowMissingTokenValues} : 0);

    my @tokenized;

    foreach my $arg(@{$args{args}}) {  # AAARRRRGSSS MATEY!
        while ($arg =~ /(@)([^@]+)(@)/) {
           my $token = $2;
           if (! defined($args{tokens})) {
               die "tokens not defined. cannot resolve token '$token'";
           }
           else {
               my $value = $args{tokens}->{$token};
               if (defined $value) {
                   $arg =~ s/$1$2$3/$value/;  
               }
               elsif (!$allowMissingTokenValues) {
                   die "value for token '$token' not found";
               } 
               #print "arg is now: $arg\n";
           } 
        }

        push(@tokenized, $arg);
    }

    return join(" ", @tokenized);
}

#-----------------------------------------------------------------------------
sub getProgConfig {
    my $s = shift;
    my $name = shift || die "no name";
    if (defined $s->{progs}->{$name}) {
        return $s->{progs}->{$name};
    }
    else {
        die "config for program '$name' not found";
    }
}

#-----------------------------------------------------------------------------
sub getProgPath {
    my $s = shift;
    my $name = shift || die "no name";
    my $config = $s->getProgConfig($name);
    if (defined $config->{path}) {
        return $config->{path};
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

    #print "args (" . ref($args{args})  . "):\n", Dumper(\%args);

    my $outputPrefix = (defined $args{outputPrefix} ? $args{outputPrefix} : 1); 

    if (ref($args{args}) eq 'HASH') {
        while (my($batchName, $batchArgs) = each %{$args{args}}) {
            print "doing command batch '$batchName'\n";
            my $command = $s->getCommandWithArgs(
                prog => $args{prog}, 
                args => $batchArgs, 
                tokens => $args{tokens}
            );
            $s->doCommand($command, $outputPrefix, $s->{dryRun});
        }
    }    
    else {
        print "command is not a batch command.\n";
        my $command = $s->getCommandWithArgs(%args);
        $s->doCommand($command, $outputPrefix, $s->{dryRun});
    } 
}



#-----------------------------------------------------------------------------
sub registerPid {
    my $s = shift;
    my $pid = shift || die "no pid received";
    unshift(@{$s->{childPids}}, $pid);
}

#-----------------------------------------------------------------------------
sub cleanUp {
    my $s = shift;
    my $exitCode = shift;
    my $error = shift;
    if ($error) {
        print "ERROR: $error";
    }

    my @pids;
    if (scalar(@{$s->{childPids}})) {
        push (@pids, @{$s->{childPids}});
    }
    if (scalar(@{$s->{cmd}->{childPids}})) {
        push (@pids, @{$s->{cmd}->{childPids}});
    }

    if (@pids) {
        print "killing children: ", join(',', @pids), "\n";
        kill 15, @pids;
    }
    if (defined $exitCode) {
        exit($exitCode);
    }
}

#-----------------------------------------------------------------------------
sub handleInt {
    my $s = shift;
    print "caught INT\n";
    $s->cleanUp(1);
}

#=============================================================================
#
#=============================================================================
package Command::Simple;

use strict;

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
    foreach my $k qw(dryRun) {
        if (defined $args{$k}) {
            $s->{$k} = $args{$k};
        }
    }

    $s->{childPids} = [];
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

        $s->registerPid($stats{pid});

        while (my $tmp = <PH>) {
            if($showOutput) {
                if ($showOutput eq "1") {
                    print $tmp; # print the command as it runs so we aren't clueless until it's done
                }
                else {
                    print $showOutput . ': ' . $tmp; # same as a bove, but with a prefix, so we can grep out parts of the process
                }
            }
            $stats{output} .= $tmp;
        }

        CORE::close(PH) || die "command pipe close() had errors for command '$cmd'";
   
        # TODO: cleanup child pids array?
 
        $stats{rc} =  ($? >> 8);  # from perlvar man page (search for $?):
                                  # $? >> 8 returns the real return code

        if ($stats{rc} > 0) {
            die "non-zero return code from command: $cmd";
        } 
        return \%stats;
    }
}

#-----------------------------------------------------------------------------
sub registerPid {
    my $s = shift;
    my $pid = shift || die "no pid received";
    unshift(@{$s->{childPids}}, $pid);
}

#=============================================================================
#
#=============================================================================
package Video::Info;

use strict;
use warnings;

use Data::Dumper;
use File::stat;
use Format::Human::Bytes;

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
    foreach my $k qw(file) {
        if (defined $args{$k}) {
            $s->{$k} = $args{$k};
        }
    }

    $s->{mplayerPath} = $args{mplayerPath} || die "missing argument 'mplayerPath'";
    $s->{cmd} = Command::Simple->new();
}

#-----------------------------------------------------------------------------
sub readVideoFile {
    my $s = shift;
    my %args = @_;

    # sanity check
    foreach my $k qw(file) {
        if (!defined $args{$k}) {
            die "missing argument '$k'";
        }
    }

    my $info = $s->_getVideoInfo($args{file}); 

    my $human =  Format::Human::Bytes->new();
    my $stat = stat($args{file}) || die "$!";

    $info->{SIZE_HUMAN} = $human->base2($stat->size);
    #$info->{BITRATE_KBYTES} = ($info->{VIDEO_BITRATE}/8/1024);
    $info->{BITRATE_HUMAN} = $human->base2(($info->{VIDEO_BITRATE}/8));

    #foreach my $item qw(BITRATE_KBYTES) {
    #    $info->{$item} =~ s/\.(\d)(.+)/$1/;
    #}

    #$info->{BITRATE_KBITS} .= ' Kbits/sec';
    #$info->{BITRATE_KBYTES} .= ' KBytes/sec';

    return $info;
}

#-----------------------------------------------------------------------------
sub _getVideoInfo {
    my $s = shift;
    my $file = shift || die "no file";
    my $key = shift;

    # http://lists.mplayerhq.hu/pipermail/mplayer-users/2007-March/066366.html
    my $opts = "-identify -vo null -ao null -frames 0 $file";

    if ($key) {
        my $result = $s->{cmd}->doCommand("$s->{mplayerPath} $opts | grep $key", 0, 0);
        my $output = $result->{output};
        $output =~ s/$key=//;
        return $output;
    }
    else {
        my %info;
        my $result = $s->{cmd}->doCommand("$s->{mplayerPath} $opts", 0, 0);
        #my $result = $s->runProg(name => "mplayer", args => $opts, showOutput => 0, dryRun => 0);
        foreach my $line(split(/\n/, $result->{output})) {
            next if ($line !~ /=/ || $line !~ /^ID_/);
            my ($k,$v) = split('=', $line);
            $k =~ s/^ID_//g;
            $info{$k} = $v;
        }
        return \%info;
    }
}

1;
