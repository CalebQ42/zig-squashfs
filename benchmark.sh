#! /usr/bin/env bash

ARCHIVE="testing/LinuxPATest.sfs"

if [ ! -z $1 ]; then
	ARCHIVE=$1
fi

echo "Benchmarking on archive $ARCHIVE"

REF_EXT_LOC="testing/BenchmarkReference"
PROG_EXT_LOC="testing/BenchmarkBinTest"

echo ""
echo "Building with ReleaseFast"
echo ""

zig build -Doptimize=fast

echo ""
echo "Testing Multi-threaded Performance"
echo ""

hyperfine --warmup 5 --prepare "rm -rf $REF_EXT_LOC && rm -rf $PROG_EXT_LOC" "unsquashfs -d $REF_EXT_LOC $ARCHIVE" "zig-out/bin/unsquashfs -d $PROG_EXT_LOC $ARCHIVE"

echo ""
echo "Testing Single-threaded Performance"
echo ""

hyperfine --warmup 5 --prepare "rm -rf $REF_EXT_LOC && rm -rf $PROG_EXT_LOC" "unsquashfs -p 1 -d $REF_EXT_LOC $ARCHIVE" "zig-out/bin/unsquashfs -p 1 -d $PROG_EXT_LOC $ARCHIVE"

echo ""
echo "Building with ReleaseFast and zig_decomp"
echo ""

zig build -Doptimize=fast -Dzig_decomp=true

echo ""
echo "Testing Multi-threaded Performance"
echo ""

hyperfine --warmup 5 --prepare "rm -rf $REF_EXT_LOC && rm -rf $PROG_EXT_LOC" "unsquashfs -d $REF_EXT_LOC $ARCHIVE" "zig-out/bin/unsquashfs -d $PROG_EXT_LOC $ARCHIVE"

echo ""
echo "Testing Single-threaded Performance"
echo ""

hyperfine --warmup 5 --prepare "rm -rf $REF_EXT_LOC && rm -rf $PROG_EXT_LOC" "unsquashfs -p 1 -d $REF_EXT_LOC $ARCHIVE" "zig-out/bin/unsquashfs -p 1 -d $PROG_EXT_LOC $ARCHIVE"
