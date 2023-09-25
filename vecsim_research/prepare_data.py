import numpy as np
import pandas as pd
import os
import itertools
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

            text_item_keywords_vector = text_vector_dict[key].astype(np.float32).tobytes()
            item_metadata[text_vector_field_name]=text_item_keywords_vector

            img_item_keywords_vector = img_vector_dict[key].astype(np.float32).tobytes()
            item_metadata[img_vector_field_name]=img_item_keywords_vector
            # HSET
            p.hset(hashkey,mapping=item_metadata)

        p.execute()
        i+=1


def create_flat_index (redis_conn, text_emb_vector_field_name, img_emb_vector_field_name, number_of_vectors, vector_dimensions=512, distance_metric='L2'):
    redis_conn.ft("idx:vecsim").create_index([
        VectorField(text_emb_vector_field_name, "FLAT", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric, "INITIAL_CAP": number_of_vectors, "BLOCK_SIZE":number_of_vectors }),
        VectorField(img_emb_vector_field_name, "FLAT", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric, "INITIAL_CAP": number_of_vectors, "BLOCK_SIZE":number_of_vectors }),
        TextField("caption"),
        TextField("url"),
        TextField("primary_key"),
    ])


def create_hnsw_index (redis_conn, text_emb_vector_field_name, img_emb_vector_field_name, number_of_vectors, vector_dimensions=512, distance_metric='L2', M=40, EF=200):
    redis_conn.ft("idx:vecsim").create_index([
        VectorField(text_emb_vector_field_name, "HNSW", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric, "INITIAL_CAP": number_of_vectors, "M": M, "EF_CONSTRUCTION": EF}),
        VectorField(img_emb_vector_field_name, "HNSW", {"TYPE": "FLOAT32", "DIM": vector_dimensions, "DISTANCE_METRIC": distance_metric, "INITIAL_CAP": number_of_vectors, "M": M, "EF_CONSTRUCTION": EF}),   
        TextField("caption"),
        TextField("url"),
        TextField("primary_key"),
    ])    


TEXT_ITEM_KEYWORD_EMBEDDING_FIELD='text_item_emb_vector'
IMG_ITEM_EMBEDDING_FIELD='img_item_emb_vector'
EMBEDDING_DIMENSION=512
DATA_DIR = "data"

files_in_data = os.listdir(DATA_DIR)
files_in_data.sort()

metadata = None
img_emb = None
text_emb = None

for file in files_in_data:
    file_path = os.path.join(DATA_DIR, file)
    if "metadata_" in file:
        if metadata is None:
            metadata = pd.read_parquet(file_path, engine='fastparquet')
        else:
            metadata = pd.merge(metadata, pd.read_parquet(file_path, engine='fastparquet'), how="outer")
    elif "img_emb_" in file:
        if img_emb is None:
            img_emb = np.load(file_path)
        else:
            img_emb = np.append(img_emb, np.load(file_path))
    elif "text_emb_" in file:
        if text_emb is None:
            text_emb = np.load(file_path)
        else:
            text_emb = np.append(text_emb, np.load(file_path))
    else:
        print(f"Ignoring file {file}")

metadata["primary_key"] = "Item:" + metadata.index.astype(str)
metadata = metadata[["primary_key", "caption", "url"]]
product_metadata = metadata.to_dict(orient='index')

NUMBER_PRODUCTS=len(product_metadata)


host = 'localhost'
port = 5000
redis_conn = Redis(host=host, port=port)
print(redis_conn.ping())
print("Connected to Redis")

#flush all data
redis_conn.flushall()

print ('Loading and Indexing ' +  str(NUMBER_PRODUCTS) + ' products...')

#create flat index & load vectors
create_flat_index(redis_conn, TEXT_ITEM_KEYWORD_EMBEDDING_FIELD, IMG_ITEM_EMBEDDING_FIELD, NUMBER_PRODUCTS, EMBEDDING_DIMENSION, 'COSINE')
load_vectors(redis_conn, product_metadata, text_emb, img_emb, TEXT_ITEM_KEYWORD_EMBEDDING_FIELD, IMG_ITEM_EMBEDDING_FIELD)
