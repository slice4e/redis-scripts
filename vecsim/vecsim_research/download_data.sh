#!/bin/bash

echo "This script will download metadata, text and image embeddings from LAION dataset: https://the-eye.eu/public/AI/cah/laion400m-met-release/laion400m-embeddings"
echo "Dataset contains of 410 parts, please provide range of files that you want to download (beetween 0 and 409)"

read -p "Download from part number(0-409): " start_range
if [ $start_range -lt 0 ] || [ $start_range -gt 409 ]; then
    echo "Wrong number"
    exit 1
fi

read -p "Download to part number($start_range-409): " end_range
if [ $end_range -lt $start_range ] || [ $start_range -gt 409 ]; then
    echo "Wrong number"
    exit 1
fi

part=$start_range
while [ $part -le $end_range ]
do
    echo "Downloading image embedding file from: https://the-eye.eu/public/AI/cah/laion400m-met-release/laion400m-embeddings/images/img_emb_$part.npy"
    wget  https://the-eye.eu/public/AI/cah/laion400m-met-release/laion400m-embeddings/images/img_emb_$part.npy
    echo "Downloading metadata file from: https://the-eye.eu/public/AI/cah/laion400m-met-release/laion400m-embeddings/metadata/metadata_$part.parquet"
    wget  https://the-eye.eu/public/AI/cah/laion400m-met-release/laion400m-embeddings/metadata/metadata_$part.parquet
    echo "Downloading text embedding file from: https://the-eye.eu/public/AI/cah/laion400m-met-release/laion400m-embeddings/texts/text_emb_$part.npy"
    wget  https://the-eye.eu/public/AI/cah/laion400m-met-release/laion400m-embeddings/texts/text_emb_$part.npy
    ((part++))
done
