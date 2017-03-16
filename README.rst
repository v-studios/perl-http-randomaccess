========
 README
========

The ``exiftool`` command handles the arguments then invokes module
ExifTool.pm::

        $info = $et->ImageInfo(Infile($pipe), \@foundTags);

The ExifTool.pm creates a Random Access File object using the RAF
library, also written by exiftool's author::

            if ($self->Open(\*EXIFTOOL_FILE, $filename)) {
                # create random access file object
                $raf = new File::RandomAccess(\*EXIFTOOL_FILE);

We could replace the $raf->Function() calls with some new calls to
read from HTTP. Unless all the submodules also use RAF, in which case
there's a lot of code to change.

Turns out ExifTool.pm 'require's a libary based on the file type, so
for a .mov file it opens QuickTime.pm and invokes ProcessMOV::

                require "Image/ExifTool/$module.pm";
                $func = "Image::ExifTool::${module}::$func";

The media-type-specific module does in fact have calls to
$raf->Seek(), Tell(), Read(). All the sublibraries use $raf calls.

After defining all the extraction patterns and functions, it returns
to ExifTool.pm to process it::

            # process the file
            no strict 'refs';
            my $result = &$func($self, \%dirInfo);

This library is supposed to mimic File::RandomAccess replacing all its
seek(), tell(), read() calls with ones that read from HTTP using byte
ranges.  We should then be able to do something like::

 $raf = httpRandomAccess(URL)
 $raf->Seek(0xCAFEBABE, 0)
 $raf->Read(42)
 $raf->Tell()
