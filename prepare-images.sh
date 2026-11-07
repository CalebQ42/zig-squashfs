#!/usr/bin/env bash

if [[ -z $1 ]]; then
	echo "Please specify a directory!"
	exit 0
fi

mkdir testing

echo ""
echo "Making no compression version at testing/no-comp-test-image.sfs ..."
echo ""

mksquashfs $1 testing/no-comp-test-image.sfs -no-compression

echo "Making gzip version at testing/gzip-test-image.sfs ..."
echo ""

mksquashfs $1 testing/gzip-test-image.sfs -comp gzip

echo ""
echo "Making lzo version at testing/lzo-test-image.sfs ..."
echo ""

mksquashfs $1 testing/lzo-test-image.sfs -comp lzo

echo ""
echo "Making lz4 version at testing/lz4-test-image.sfs ..."
echo ""

mksquashfs $1 testing/lz4-test-image.sfs -comp lz4

echo ""
echo "Making xz version at testing/xz-test-image.sfs ..."
echo ""
mksquashfs $1 testing/xz-test-image.sfs -comp xz

echo ""
echo "Making zstd version at testing/zstd-test-image.sfs ..."
echo ""

mksquashfs $1 testing/zstd-test-image.sfs -comp zstd

echo ""
echo "Making lzma version at testing/lzma-test-image.sfs ..."
echo ""

mksquashfs $1 testing/lzma-test-image.sfs -comp lzma