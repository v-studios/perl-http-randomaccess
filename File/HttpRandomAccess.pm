#------------------------------------------------------------------------------
# File:         RandomAccess.pm
#
# Description:  Buffer to support random access reading of sequential file
#
# Revisions:    02/11/2004 - P. Harvey Created
#               02/20/2004 - P. Harvey Added flag to disable SeekTest in new()
#               11/18/2004 - P. Harvey Fixed bug with seek relative to end of file
#               01/02/2005 - P. Harvey Added DEBUG code
#               01/09/2006 - P. Harvey Fixed bug in ReadLine() when using
#                            multi-character EOL sequences
#               02/20/2006 - P. Harvey Fixed bug where seek past end of file could
#                            generate "substr outside string" warning
#               06/10/2006 - P. Harvey Decreased $CHUNK_SIZE from 64k to 8k
#               11/23/2006 - P. Harvey Limit reads to < 0x80000000 bytes
#               11/26/2008 - P. Harvey Fixed bug in ReadLine when reading from a
#                            scalar with a multi-character newline
#               01/24/2009 - PH Protect against reading too much at once
#
# Notes:        Calls the normal file i/o routines unless SeekTest() fails, in
#               which case the file is buffered in memory to allow random access.
#               SeekTest() is called automatically when the object is created
#               unless specified.
#
#               May also be used for string i/o (just pass a scalar reference)
#
# Legal:        Copyright (c) 2003-2017 Phil Harvey (phil at owl.phy.queensu.ca)
#               This library is free software; you can redistribute it and/or
#               modify it under the same terms as Perl itself.
#------------------------------------------------------------------------------

package File::HttpRandomAccess;

use strict;
require 5.002;
require Exporter;

use LWP;

use vars qw($VERSION @ISA @EXPORT_OK);
$VERSION = '1.10';
@ISA = qw(Exporter);

sub Read($$$);

# constants
my $CHUNK_SIZE = 8192;  # size of chunks to read from file (must be power of 2)
my $SLURP_CHUNKS = 16;  # read this many chunks at a time when slurping


sub http_read_range($;$;$)
{
    my ($url, $bytestart, $byteend) = @_;
    my $browser = LWP::UserAgent->new;
    my @headers = ('Range' => "bytes=$bytestart-$byteend");
    my $response = $browser->get($url, @headers);

    print "http_read_range response range=$response->header('Content-Range')";
    # TODO: check for success/fail
    return $response;  # consume must be able to read headers
}

#------------------------------------------------------------------------------
# Create new RandomAccess object
# Inputs: 0) reference to RandomAccess object or RandomAccess class name
#         1) file reference or scalar reference
#         2) flag set if file is already random access (disables automatic SeekTest)
sub new($$;$)
{
    my ($that, $url, $isRandom) = @_;
    my $class = ref($that) || $that;
    my $self;

    # We'll have to change ExifTool.pm:2079 to pass URL, not open filepointer.

    my $buff = '';
    $self = {
        HTTP_URL => $url,
        FILE_PT => 'NOTHING', # file pointer
        BUFF_PT => \$buff,  # reference to file data
        POS => 0,           # current position in file
        LEN => 0,           # data length
        TESTED => 0,        # 0=untested, 1=passed, -1=failed (requires buffering)
    };
    bless $self, $class;
    $self->SeekTest() unless $isRandom;
    return $self;
    # do I want to try and get range bytes=0-0 to find the file length and set LEN
}

#------------------------------------------------------------------------------
# Enable DEBUG code
# Inputs: 0) reference to RandomAccess object
sub Debug($)
{
    my $self = shift;
    $self->{DEBUG} = { };
}

#------------------------------------------------------------------------------
# Perform seek test and turn on buffering if necessary
# Inputs: 0) reference to RandomAccess object
# Returns: 1 if seek test passed (ie. no buffering required)
# Notes: Must be done before any other i/o
sub SeekTest($)
{
    # We can't seek() on HTTP so we'll return failure, requiring buffering.
    my $self = shift;
    my $url = $self->{HTTP_URL};
    print "SeekTest url=", $url;
    my $resp = http_read_range($url, 0, 0);

    # Content-Range: bytes 0-0/2505094
    # Content-Range: bytes 0-80/2505094  <-- why not 0-0??
    my $range = $resp->header('Content-Range');
    print "SeekTest range=", $range;
    my @vals = split('/', $range);
    my $len = int($vals[1]);
    $self->{HTTP_LEN} = $len;
    print "SeekTest HTTP_LEN=", $self->{HTTP_LEN};
    unless ($self->{TESTED}) {
        $self->{TESTED} = -1;   # test failed (requires buffering)
    }
    return $self->{TESTED} == 1 ? 1 : 0;
}

#------------------------------------------------------------------------------
# Get current position in file
# Inputs: 0) reference to RandomAccess object
# Returns: current position in file
sub Tell($)
{
    my $self = shift;
    my $rtnVal;
    if ($self->{TESTED} < 0) {
        $rtnVal = $self->{POS};
    } else {
        $rtnVal = tell($self->{FILE_PT});
    }
    return $rtnVal;
}

#------------------------------------------------------------------------------
# Seek to position in file
# Inputs: 0) reference to RandomAccess object
#         1) position, 2) whence (0 or undef=from start, 1=from cur pos, 2=from end)
# Returns: 1 on success
# Notes: When buffered, this doesn't quite behave like seek() since it will return
#        success even if you seek outside the limits of the file.  However if you
#        do this, you will get an error on your next Read().
#
# UNIX seek(fd, offset, whence) returns resulting offset location from BOF
#      whence: 0=from start, 1=from curr pos, 2=from end

sub Seek($$;$)
{
    my ($self, $num, $whence) = @_;
    $whence = 0 unless defined $whence;
    my $rtnVal;
    # We're always gonna be TESTED<0
    if ($self->{TESTED} < 0) {
        my $newPos;
        if ($whence == 0) {
            $newPos = $num;                 # from start of file
        } elsif ($whence == 1) {
            $newPos = $num + $self->{POS};  # relative to current position
        } else {
            # Don't slurp here, read only what we need in Read()
            # $self->Slurp();                 # read whole file into buffer
            $newPos = $num + $self->{LEN};  # relative to end of file
        }
        if ($newPos >= 0) {
            $self->{POS} = $newPos;
            $rtnVal = 1;
        }
    } else {
        $rtnVal = seek($self->{FILE_PT}, $num, $whence);
    }
    return $rtnVal;
}

#------------------------------------------------------------------------------
# Read from the file
# Inputs: 0) reference to RandomAccess object, 1) buffer, 2) bytes to read
# Returns: Number of bytes read
sub Read($$$)
{
    my $self = shift;
    my $len = $_[1];
    my $rtnVal;

    # protect against reading too much at once
    # (also from dying with a "Negative length" error)
    if ($len & 0xf8000000) {  ## TODO don't know what to do about this stuff
        return 0 if $len < 0;
        # read in smaller blocks because Windows attempts to pre-allocate
        # memory for the full size, which can lead to an out-of-memory error
        my $maxLen = 0x4000000; # (MUST be less than bitmask in "if" above)
        my $num = Read($self, $_[0], $maxLen);
        return $num if $num < $maxLen;
        for (;;) {
            $len -= $maxLen;
            last if $len <= 0;
            my $l = $len < $maxLen ? $len : $maxLen;
            my $buff;
            my $n = Read($self, $buff, $l);
            last unless $n;
            $_[0] .= $buff;
            $num += $n;
            last if $n < $l;
        }
        return $num;
    }
    # read through our buffer if necessary
    if ($self->{TESTED} < 0) {
        my $buff;
        my $newPos = $self->{POS} + $len;
        # number of bytes to read from file
        my $num = $newPos - $self->{LEN};

        my $resp = http_read_range($self->{HTTP_URL}, $self->{POS}, $newPos);
        my $range = $resp->header('Content-Range');
        my @vals = split('/', $range);
        my @bytes = split('-', $vals[0]);
        my $len = int($bytes[1]) - int($bytes[0]);
        $self->{POS} += $len;
        $_[0] = $resp->content;
        $rtnVal = $len;

        # if ($num > 0 and $self->{FILE_PT}) {
        #     # read data from file in multiples of $CHUNK_SIZE
        #     $num = (($num - 1) | ($CHUNK_SIZE - 1)) + 1;
        #     $num = read($self->{FILE_PT}, $buff, $num);
        #     if ($num) {
        #         ${$self->{BUFF_PT}} .= $buff;
        #         $self->{LEN} += $num;
        #     }
        # }
        # # number of bytes left in data buffer
        # $num = $self->{LEN} - $self->{POS};
        # if ($len <= $num) {
        #     $rtnVal = $len;
        # } elsif ($num <= 0) {
        #     $_[0] = '';
        #     return 0;
        # } else {
        #     $rtnVal = $num;
        # }
        # # return data from our buffer
        # $_[0] = substr(${$self->{BUFF_PT}}, $self->{POS}, $rtnVal);
        # $self->{POS} += $rtnVal;
    } else {
        # read directly from file
        $_[0] = '' unless defined $_[0];
        $rtnVal = read($self->{FILE_PT}, $_[0], $len) || 0;
    }
    if ($self->{DEBUG}) {
        my $pos = $self->Tell() - $rtnVal;
        unless ($self->{DEBUG}->{$pos} and $self->{DEBUG}->{$pos} > $rtnVal) {
            $self->{DEBUG}->{$pos} = $rtnVal;
        }
    }
    return $rtnVal;
}

#------------------------------------------------------------------------------
# Read a line from file (end of line is $/)
# Inputs: 0) reference to RandomAccess object, 1) buffer
# Returns: Number of bytes read
sub ReadLine($$)
{
    # TODO: how do we do this, if we've nixed the buffer in Read() ?
    my $self = shift;
    my $rtnVal;
    my $fp = $self->{FILE_PT};

    if ($self->{TESTED} < 0) {
        my ($num, $buff);
        my $pos = $self->{POS};
        if ($fp) {
            # make sure we have some data after the current position
            while ($self->{LEN} <= $pos) {
                $num = read($fp, $buff, $CHUNK_SIZE);
                return 0 unless $num;
                ${$self->{BUFF_PT}} .= $buff;
                $self->{LEN} += $num;
            }
            # scan and read until we find the EOL (or hit EOF)
            for (;;) {
                $pos = index(${$self->{BUFF_PT}}, $/, $pos);
                if ($pos >= 0) {
                    $pos += length($/);
                    last;
                }
                $pos = $self->{LEN};    # have scanned to end of buffer
                $num = read($fp, $buff, $CHUNK_SIZE) or last;
                ${$self->{BUFF_PT}} .= $buff;
                $self->{LEN} += $num;
            }
        } else {
            # string i/o
            $pos = index(${$self->{BUFF_PT}}, $/, $pos);
            if ($pos < 0) {
                $pos = $self->{LEN};
                $self->{POS} = $pos if $self->{POS} > $pos;
            } else {
                $pos += length($/);
            }
        }
        # read the line from our buffer
        $rtnVal = $pos - $self->{POS};
        $_[0] = substr(${$self->{BUFF_PT}}, $self->{POS}, $rtnVal);
        $self->{POS} = $pos;
    } else {
        $_[0] = <$fp>;
        if (defined $_[0]) {
            $rtnVal = length($_[0]);
        } else {
            $rtnVal = 0;
        }
    }
    if ($self->{DEBUG}) {
        my $pos = $self->Tell() - $rtnVal;
        unless ($self->{DEBUG}->{$pos} and $self->{DEBUG}->{$pos} > $rtnVal) {
            $self->{DEBUG}->{$pos} = $rtnVal;
        }
    }
    return $rtnVal;
}

#------------------------------------------------------------------------------
# Read whole file into buffer (without changing read pointer)
# Inputs: 0) reference to RandomAccess object
sub Slurp($)
{
    my $self = shift;
    my $fp = $self->{FILE_PT} || return;
    # read whole file into buffer (in large chunks)
    my ($buff, $num);
    while (($num = read($fp, $buff, $CHUNK_SIZE * $SLURP_CHUNKS)) != 0) {
        ${$self->{BUFF_PT}} .= $buff;
        $self->{LEN} += $num;
    }
}


#------------------------------------------------------------------------------
# set binary mode
# Inputs: 0) reference to RandomAccess object
sub BinMode($)
{
    my $self = shift;
    binmode($self->{FILE_PT}) if $self->{FILE_PT};
}

#------------------------------------------------------------------------------
# close the file and free the buffer
# Inputs: 0) reference to RandomAccess object
sub Close($)
{
    my $self = shift;

    if ($self->{DEBUG}) {
        local $_;
        if ($self->Seek(0,2)) {
            $self->{DEBUG}->{$self->Tell()} = 0;    # set EOF marker
            my $last;
            my $tot = 0;
            my $bad = 0;
            foreach (sort { $a <=> $b } keys %{$self->{DEBUG}}) {
                my $pos = $_;
                my $len = $self->{DEBUG}->{$_};
                if (defined $last and $last < $pos) {
                    my $bytes = $pos - $last;
                    $tot += $bytes;
                    $self->Seek($last);
                    my $buff;
                    $self->Read($buff, $bytes);
                    my $warn = '';
                    if ($buff =~ /[^\0]/) {
                        $bad += ($pos - $last);
                        $warn = ' - NON-ZERO!';
                    }
                    printf "0x%.8x - 0x%.8x (%d bytes)$warn\n", $last, $pos, $bytes;
                }
                my $cur = $pos + $len;
                $last = $cur unless defined $last and $last > $cur;
            }
            print "$tot bytes missed";
            $bad and print ", $bad non-zero!";
            print "\n";
        } else {
            warn "File::RandomAccess DEBUG not working (file already closed?)\n";
        }
        delete $self->{DEBUG};
    }
    # close the file
    if ($self->{FILE_PT}) {
        close($self->{FILE_PT});
        delete $self->{FILE_PT};
    }
    # reset the buffer
    my $emptyBuff = '';
    $self->{BUFF_PT} = \$emptyBuff;
    $self->{LEN} = 0;
    $self->{POS} = 0;
}

#------------------------------------------------------------------------------
1;  # end
