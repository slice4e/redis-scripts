#!/bin/bash

grep -E '\[*\]' -H *-perf.txt | sort -g -r -k 2 > all.combined.report
grep -E '\[k\]'  all.combined.report > kernel.combined.report
grep -E '\[\.\]' all.combined.report > user.combined.report
