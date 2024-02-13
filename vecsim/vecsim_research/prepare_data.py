import numpy as np
import pandas as pd
import os
import itertools
import argparse

from time import time
from redis import Redis
from redis.commands.search.field import VectorField
from redis.commands.search.field import TextField
from redis.cluster import RedisCluster

def chunk(it, size):
    it = iter(it)
    while True:
        p = dict(itertools.islice(it, size))
        if not p:
            break
        yield p

def load_vectors(client:Redis, product_metadata, text_vector_dict, img_vector_dict, text_vector_field_name, img_vector_field_name):
    i=0
    for batch in chunk(product_metadata.items(), 10000):
        #process batch 
        print (f'processing batch {i}')
        p = client.pipeline(transaction=False)
        for key in batch.keys():    
            #hash key
            hashkey=batch[key]['primary_key']

            #hash values
            item_metadata = batch[key]

            if text_vector_dict is not None:
                text_item_keywords_vector = text_vector_dict[key].astype(np.float32).tobytes()
                item_metadata[text_vector_field_name]=text_item_keywords_vector

            if img_vector_dict is not None:
                img_item_keywords_vector = img_vector_dict[key].astype(np.float32).tobytes()
                item_metadata[img_vector_field_name]=img_item_keywords_vector

            # HSET
            p.hset(hashkey,mapping=item_metadata)

        p.execute()
        i+=1

def create_flat_index(redis_conn, text_emb_vector_field_name, img_emb_vector_field_name, vector_dimensions=512, distance_metric='L2'):
    fields = [TextField("caption"),
              TextField("url"),
              TextField("primary_key")]
    if text_emb_vector_field_name is not None:
        fields.append(VectorField(text_emb_vector_field_name, "FLAT", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric}))
    if img_emb_vector_field_name is not None:
        fields.append(VectorField(img_emb_vector_field_name, "FLAT", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric}))
    redis_conn.ft().create_index(fields)

def create_hnsw_index(redis_conn, text_emb_vector_field_name, img_emb_vector_field_name, vector_dimensions=512, distance_metric='L2', M=40, EF=200):
    fields = [TextField("caption"),
              TextField("url"),
              TextField("primary_key")]
    if text_emb_vector_field_name is not None:
        fields.append(VectorField(text_emb_vector_field_name, "HNSW", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric, "M": M, "EF_CONSTRUCTION": EF}))
    if img_emb_vector_field_name is not None:
        fields.append(VectorField(img_emb_vector_field_name, "HNSW", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric, "M": M, "EF_CONSTRUCTION": EF}))
    redis_conn.ft().create_index(fields)    

def parse_cmd_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=str, required=True, help="Path to the data directory")
    parser.add_argument("--hnsw-index", action="store_true", help="Create hnsw index instead of flat")
    parser.add_argument("--no-index", action="store_true", help="Don't create index, just load the data to redis server")
    parser.add_argument("--no-upload", action="store_true", help="Don't upload the data, just create search index")
    parser.add_argument("--redis-port", "-p", dest="port", type=str, default="6379", help="Port of redis server")
    parser.add_argument("--img-emb", action="store_true", help="Use if image embeddings are to be included in hash")
    parser.add_argument("--no-text-emb", action="store_true", help="Use if text embeddings are not to be included in hash")
    parser.add_argument("--cluster", action="store_true", help="Connect to redis cluster instead of redis server")
    args = parser.parse_args()
    return args

def main():
    script_start_time = time()
    args = parse_cmd_args()

    TEXT_ITEM_KEYWORD_EMBEDDING_FIELD='text_item_emb_vector' if not args.no_text_emb else None
    IMG_ITEM_EMBEDDING_FIELD='img_item_emb_vector' if args.img_emb else None
    EMBEDDING_DIMENSION=512
    DATA_DIR = args.data_dir

    files_in_data = os.listdir(DATA_DIR)
    files_in_data.sort()

    indexes = 0

    metadata_files = []
    img_emb_files = []
    text_emb_files = []
    
    for file in files_in_data:
        file_path = os.path.join(DATA_DIR, file)
        if "metadata_" in file:
            metadata_files.append(file_path)
        elif "img_emb_" in file:
            img_emb_files.append(file_path)
        elif "text_emb_" in file:
            text_emb_files.append(file_path)
        else:
            print(f"Ignoring file {file}")

    host = 'localhost'
    port = args.port
    if args.cluster:
        redis_conn = RedisCluster(host=host, port=port)
        print(redis_conn.ping())
        print(f"Connected to Redis cluster {host}:{port}")
    else:
        redis_conn = Redis(host=host, port=port)
        print(redis_conn.ping())
        print(f"Connected to Redis server {host}:{port}")

    #flush all data
    if not args.no_upload:
        redis_conn.flushall()

    #create flat index & load vectors
    create_index_start_time = time()
    if args.no_index:
        index_type = "None"
    else:
        if args.hnsw_index:
            index_type = "hnsw"
            create_hnsw_index(redis_conn, TEXT_ITEM_KEYWORD_EMBEDDING_FIELD, IMG_ITEM_EMBEDDING_FIELD, EMBEDDING_DIMENSION, 'COSINE', M=40, EF=200)
        else:
            index_type = "flat"
            create_flat_index(redis_conn, TEXT_ITEM_KEYWORD_EMBEDDING_FIELD, IMG_ITEM_EMBEDDING_FIELD, EMBEDDING_DIMENSION, 'COSINE')
    create_index_end_time = time()
    create_index_time = create_index_end_time - create_index_start_time

    if not args.no_upload:
        num_of_files = len(metadata_files)
        loading_start_time = time()
        for num in range(0, num_of_files):
            debug = "Working on files: "
            metadata = pd.read_parquet(metadata_files[num], engine='fastparquet')
            debug = debug + str(metadata_files[num])
            metadata["primary_key"] = "Item:" + (metadata.index + indexes - 1).astype(str)
            metadata = metadata[["primary_key", "caption", "url"]]
            product_metadata = metadata.to_dict(orient='index')
            NUMBER_PRODUCTS=len(product_metadata)

            if args.img_emb:
                img_emb = np.load(img_emb_files[num])
                debug = debug + " " + str(img_emb_files[num])
            else:
                img_emb = None

            if not args.no_text_emb:
                text_emb = np.load(text_emb_files[num])
                debug = debug + " " + str(text_emb_files[num])
            else:
                text_emb = None

            print(debug)
            print(f"Already loaded {indexes} items")
            print ('Loading ' +  str(NUMBER_PRODUCTS) + ' items...')
            indexes = indexes + NUMBER_PRODUCTS  
            load_vectors(redis_conn, product_metadata, text_emb, img_emb, TEXT_ITEM_KEYWORD_EMBEDDING_FIELD, IMG_ITEM_EMBEDDING_FIELD)
        
        loading_end_time = time()
        loading_time = loading_end_time - loading_start_time
    else:
        loading_time = "None"
    
    script_end_time = time()
    script_time = script_end_time - script_start_time

    print(f"""Index type: {index_type}
              Total script time: {script_time}
              Creating index time: {create_index_time}
              Loading vectors time: {loading_time}""")

if __name__ == "__main__":
    main()
