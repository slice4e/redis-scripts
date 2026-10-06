#!/bin/bash

EMON_TMP_FOLDER=emon-tmp
EMON_RESULT_FOLDER=emon_processed
EMON_TMP_CONFIG=emon_config.txt
mkdir -p $EMON_TMP_FOLDER
mkdir -p $EMON_RESULT_FOLDER

if [[ $RUN_EMON == true ]] ; then
	source $EMON_HOME/sep_vars.sh
fi

for i in $( ls *.dat )
do 
    filename=${i%.*}
    test=${i%-emon.dat}

    # EMON collects during iteration 1; ops are written in scientific notation
    RESULT_FILE=${test}-run1.csv
    OPS=""
    if [ -f "$RESULT_FILE" ]; then
	    OPS=$(printf '%.0f' $(grep Ops/sec $RESULT_FILE | awk -F, '{print $3}'))
    fi

    echo "Creating emon.dat for ${i}"
    cp $i $EMON_TMP_FOLDER/emon.dat
    cp $EMON_CONFIG_FILE $EMON_TMP_FOLDER/$EMON_TMP_CONFIG
    
    cd $EMON_TMP_FOLDER
    echo "Creating a custom config file for $i)"
    echo "TPS=$OPS" >> $EMON_TMP_CONFIG

    echo "Processing edp..."
    emon -process-pyedp $EMON_TMP_CONFIG
    echo "Edp processing completed, moving results..."
    echo "mv summary.xlsx $EMON_RESULT_FOLDER/$filename-summary.xlsx"
    mv summary.xlsx ../$EMON_RESULT_FOLDER/$filename-summary.xlsx
    for f in __mpp_*.csv; do
        mv "$f" "../$EMON_RESULT_FOLDER/${filename}-${f#__mpp_}"
    done
    rm -f $EMON_TMP_CONFIG
    cd ..
    echo "Completed - ${i}"
done
rm -rf $EMON_TMP_FOLDER
echo "Process completed"

