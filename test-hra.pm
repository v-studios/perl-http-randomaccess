#!/usr/bin/env perl
# Read a range of bytes from HTTP file

use File::HttpRandomAccess;

my $url = 'http://avail-public.dev.nasawestprime.com/image/20151214_ccbeebe_popularity_mtime_test/20151214_ccbeebe_popularity_mtime_test~orig.jpg';
my $raf = new File::HttpRandomAccess($url);
