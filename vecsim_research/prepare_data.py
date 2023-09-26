import numpy as np
import pandas as pd
import os
import itertools
import argparse

from time import time
from redis import Redis
from redis.commands.search.field import VectorField
from redis.commands.search.field import TextField

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

def create_flat_index(redis_conn, text_emb_vector_field_name, img_emb_vector_field_name, number_of_vectors, vector_dimensions=512, distance_metric='L2'):
    fields = [TextField("caption"),
              TextField("url"),
              TextField("primary_key")]
    if text_emb_vector_field_name is not None:
        fields.append(VectorField(text_emb_vector_field_name, "FLAT", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric, "INITIAL_CAP": number_of_vectors, "BLOCK_SIZE":number_of_vectors }))
    if img_emb_vector_field_name is not None:
        fields.append(VectorField(img_emb_vector_field_name, "FLAT", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric, "INITIAL_CAP": number_of_vectors, "BLOCK_SIZE":number_of_vectors }))
    redis_conn.ft().create_index(fields)

def create_hnsw_index(redis_conn, text_emb_vector_field_name, img_emb_vector_field_name, number_of_vectors, vector_dimensions=512, distance_metric='L2', M=40, EF=200):
    fields = [TextField("caption"),
              TextField("url"),
              TextField("primary_key")]
    if text_emb_vector_field_name is not None:
        fields.append(VectorField(text_emb_vector_field_name, "HNSW", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric, "INITIAL_CAP": number_of_vectors, "M": M, "EF_CONSTRUCTION": EF}))
    if img_emb_vector_field_name is not None:
        fields.append(VectorField(img_emb_vector_field_name, "HNSW", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric, "INITIAL_CAP": number_of_vectors, "M": M, "EF_CONSTRUCTION": EF}))
    redis_conn.ft().create_index(fields)    

def parse_cmd_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-dir", type=str, required=True, help="Path to the data directory")
    parser.add_argument("--hnsw-index", action="store_true", help="Create hnsw index instead of flat")
    parser.add_argument("--redis-port", "-p", dest="port", type=str, default="5000", help="Port of redis server")
    parser.add_argument("--img-emb", action="store_true", help="Use if image embeddings are to be included in hash")
    parser.add_argument("--no-text-emb", action="store_true", help="Use of text embeddings are not to be included in hash")
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

    metadata = None
    img_emb = None
    text_emb = None
    
    start_time = time()
    for file in files_in_data:
        file_path = os.path.join(DATA_DIR, file)
        if "metadata_" in file:
            if metadata is None:
                metadata = pd.read_parquet(file_path, engine='fastparquet')
            else:
                metadata = pd.merge(metadata, pd.read_parquet(file_path, engine='fastparquet'), how="outer")
        elif "img_emb_" in file:
            if args.img_emb:
                if img_emb is None:
                    img_emb = np.load(file_path)
                else:
                    img_emb = np.concatenate((img_emb, np.load(file_path)))
            else:
                print(f"Ignoring file {file}")
        elif "text_emb_" in file:
            if not args.no_text_emb:
                if text_emb is None:
                    text_emb = np.load(file_path)
                else:
                    text_emb = np.concatenate((text_emb, np.load(file_path)))
            else:
                print(f"Ignoring file {file}")
        else:
            print(f"Ignoring file {file}")

    metadata["primary_key"] = "Item:" + metadata.index.astype(str)
    metadata = metadata[["primary_key", "caption", "url"]]
    product_metadata = metadata.to_dict(orient='index')
    end_time = time()
    preparing_data_time = end_time - start_time
    NUMBER_PRODUCTS=len(product_metadata)

    host = 'localhost'
    port = args.port
    redis_conn = Redis(host=host, port=port)
    print(redis_conn.ping())
    print("Connected to Redis")

    #flush all data
    redis_conn.flushall()

    print ('Loading and Indexing ' +  str(NUMBER_PRODUCTS) + ' products...')

    #create flat index & load vectors
    create_index_start_time = time()
    if args.hnsw_index:
        index_type = "hnsw"
        create_hnsw_index(redis_conn, TEXT_ITEM_KEYWORD_EMBEDDING_FIELD, IMG_ITEM_EMBEDDING_FIELD, NUMBER_PRODUCTS, EMBEDDING_DIMENSION, 'COSINE', M=40, EF=200)
    else:
        index_type = "flat"
        create_flat_index(redis_conn, TEXT_ITEM_KEYWORD_EMBEDDING_FIELD, IMG_ITEM_EMBEDDING_FIELD, NUMBER_PRODUCTS, EMBEDDING_DIMENSION, 'COSINE')
    create_index_end_time = time()
    create_index_time = create_index_end_time - create_index_start_time
    
    loading_start_time = time()
    load_vectors(redis_conn, product_metadata, text_emb, img_emb, TEXT_ITEM_KEYWORD_EMBEDDING_FIELD, IMG_ITEM_EMBEDDING_FIELD)
    loading_end_time = time()
    loading_time = loading_end_time - loading_start_time
    script_time = loading_end_time - script_start_time

    print(f"""Index type: {index_type}
              Total script time: {script_time}
              Preparing data time: {preparing_data_time}
              Creating index time: {create_index_time}
              Loading vectors time: {loading_time}""")

if __name__ == "__main__":
    main()