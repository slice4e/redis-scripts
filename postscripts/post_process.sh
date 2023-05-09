#!/bin/bash
folder=summary
summaryfile=${folder}/All-Results-Aggregated.csv
mkdir -p $folder

echo "Calculating average ops/sec across test runs"

echo "Test,Avg Ops/sec" >> $summaryfile
for i in $( ls *.csv)
do
    test=${i%-cpu*.*}
    testnum=${i#$test-cpu*-}

    if [ $testnum = "run1.csv" ]; then
    	echo -n "${test}," >> $summaryfile
    	cat ${test}*.csv | grep -E "Ops/sec" | awk -F "," '{total += $3; count++}END{ print total/count}' >> $summaryfile
    fi

done
echo "Process completed"

