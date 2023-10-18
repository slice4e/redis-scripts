import numpy as np
import argparse
from time import time
from redis.commands.search.query import Query
from redis import Redis
from redis.cluster import RedisCluster
from sentence_transformers import SentenceTransformer

def parse_cmd_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--redis-port", "-p", dest="port", type=str, default="5000", help="Port of redis server")
    parser.add_argument("--query", type=str, help="Query to run vecsim search on")
    parser.add_argument("--cluster", action="store_true", help="Connect to redis cluster instead of redis server")
    args = parser.parse_args()
    return args

def main():
    args = parse_cmd_args()

    TEXT_ITEM_KEYWORD_EMBEDDING_FIELD='text_item_emb_vector'

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

    model = SentenceTransformer('sentence-transformers/clip-ViT-B-32-multilingual-v1')

    topK=5
    if args.query is not None:
        product_query = args.query
    else:
        product_query='Stephen King'

    #vectorize the query
    query_vector = model.encode(product_query).astype(np.float32).tobytes()

    #prepare the query
    q = Query(f'*=>[KNN {topK} @{TEXT_ITEM_KEYWORD_EMBEDDING_FIELD} $vec_param AS vector_score]').sort_by('vector_score').paging(0,topK).return_fields('url','caption','primary_key').dialect(2).timeout(100000)
    params_dict = {"vec_param": query_vector}

    search_start_time = time()
    #Execute the query
    results = redis_conn.ft().search(q, query_params = params_dict)
    search_end_time = time()
    search_time = search_end_time - search_start_time
    #Print similar products found
    for product in results.docs:
        print ('***************Item found************')
        print ('url = ' + product.url)
        print ('caption = ' + product.caption)
        print ('primary_key = ' + product.primary_key)
        
    print(f"Searching time: {search_time}")

if __name__ == "__main__":
    main()
