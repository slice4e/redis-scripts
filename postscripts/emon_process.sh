#!/bin/bash

EMON_TMP_FOLDER=emon-tmp
mkdir -p $EMON_TMP_FOLDER

for i in $( ls *.dat )
do 
    filename=${i%.*}
    echo "Creating emon.dat for ${i}"
    cp $i $EMON_TMP_FOLDER/emon.dat
    cd $EMON_TMP_FOLDER
    echo "Processing edp..."
    emon -process-edp $EMON_CONFIG_FILE
    echo "Edp processing completed, moving results..."
    echo "mv summary.xlsx $EMON_RESULT_FOLDER/$filename-summary.xlsx"
    mv summary.xlsx $EMON_RESULT_FOLDER/$filename-summary.xlsx
    mv __edp_system_view_summary.csv $EMON_RESULT_FOLDER/$filename-system_view.csv
    mv __edp_socket_view_summary.csv $EMON_RESULT_FOLDER/$filename-socket_view.csv
    mv __edp_thread_view_summary.csv $EMON_RESULT_FOLDER/$filename-thread_view.csv
    rm ./*
    cd ..
    echo "Completed - ${i}"
done
echo "Process completed"

