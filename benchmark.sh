#! /usr/bin/env bash

ARCHIVE="testing/LinuxPATest.sfs"

REF_EXT_LOC="testing/LinuxPAReference"
PROG_EXT_LOC="testing/LinuxPABinTest"

echo "Testing Multi-threaded Performance"
echo ""

hyperfine --warmup 5 --prepare "rm -rf $REF_EXT_LOC && rm -rf $PROG_EXT_LOC" "unsquashfs -d $REF_EXT_LOC $ARCHIVE" "zig-out/bin/unsquashfs -d $PROG_EXT_LOC $ARCHIVE"

echo ""
echo "Testing Single-threaded Performance"
echo ""

hyperfine --warmup 5 --prepare "rm -rf $REF_EXT_LOC && rm -rf $PROG_EXT_LOC" "unsquashfs -p 1 -d $REF_EXT_LOC $ARCHIVE" "zig-out/bin/unsquashfs -p 1 -d $PROG_EXT_LOC $ARCHIVE"
