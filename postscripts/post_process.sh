#!/bin/bash
folder=summary
summaryfile=${folder}/AverageOpsSec.csv
finalsummaryfile=${folder}/All-Results-Aggregated.csv
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
echo "Calculating average completed"



echo "Aggregating all results into a summary file." 
x=0
while IFS=, read -r testname opssec
do
        if [[ $x == 0 ]]; then
                #echo "Header line"
                #echo $line
                x=1;
                continue
        fi

        echo -n "$testname,$opssec" >> $finalsummaryfile

        PERF_FILE="${testname}-perf.txt"
        if [ -f "$PERF_FILE" ]; then
                echo -n ",=hyperlink(\"../$PERF_FILE\",\"perf\")" >> $finalsummaryfile
        fi

        EMON_FILE=`ls ./emon_processed/${testname}-*-emon-summary.xlsx`
        if [ -f "$EMON_FILE" ]; then
                echo -n ",=hyperlink(\"../$EMON_FILE\",\"emon\")" >> $finalsummaryfile
        fi

        printf "\n"  >> $finalsummaryfile

done < "$summaryfile"
echo "Aggregating complete."

