#!/bin/sh

zig test \
	-lc \
	-lz \
	-llzma \
	-lminilzo \
	-llz4 \
	-lzstd \
		src/test.zig
