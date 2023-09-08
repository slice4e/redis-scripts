#!/bin/bash

# Combines the emon files from different tests (benchmark spec) into a single file for analysis
# Currently extracts the thread view and core 5, which is where we pin Redis. 

EMON_VIEW=thread_view
EMON_COLUMN=7  # corresponds to core 5
output_file=emon_combined_${EMON_VIEW}.csv

for i in $( ls *-${EMON_VIEW}.csv )
do 

	echo "Test name," > first_column.csv
	awk -v s="," -F',' '{print $1 s}' "$i" >>  first_column.csv
	break
done

for i in $( ls *-${EMON_VIEW}.csv )
do 
	filename=${i%.*}
	test=${i%-emon-${EMON_VIEW}.csv}

	echo "${test}," > ${filename}-temp.csv
	awk -v col=$EMON_COLUMN -v s="," -F',' '{print $col s}' "$i" >> ${filename}-temp.csv

done

# combine the extracted columns horizontally into the output file
paste first_column.csv *-temp.csv > "$output_file"
rm -f *-temp.csv first_column.csv

sed -i s/'\s'//g $output_file 
