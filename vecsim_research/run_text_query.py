import numpy as np
import argparse
from redis.commands.search.query import Query
from redis import Redis
from sentence_transformers import SentenceTransformer

def parse_cmd_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--redis-port", "-p", dest="port", type=str, default="5000", help="Port of redis server")
    parser.add_argument("--query", type=str, help="Query to run vecsim search on")
    args = parser.parse_args()
    return args

def main():
    args = parse_cmd_args()

    TEXT_ITEM_KEYWORD_EMBEDDING_FIELD='text_item_emb_vector'

    host = 'localhost'
    port = args.port
    redis_conn = Redis(host=host, port=port)
    print(redis_conn.ping())
    print("Connected to Redis")

    model = SentenceTransformer('sentence-transformers/clip-ViT-B-32-multilingual-v1')

    topK=5
    if args.query is not None:
        product_query = args.query
    else:
        product_query='Stephen King'

    #vectorize the query
    query_vector = model.encode(product_query).astype(np.float32).tobytes()

    #prepare the query
    q = Query(f'*=>[KNN {topK} @{TEXT_ITEM_KEYWORD_EMBEDDING_FIELD} $vec_param AS vector_score]').sort_by('vector_score').paging(0,topK).return_fields('url','caption','primary_key').dialect(2)
    params_dict = {"vec_param": query_vector}

    #Execute the query
    results = redis_conn.ft().search(q, query_params = params_dict)

    #Print similar products found
    for product in results.docs:
        print ('***************Item found************')
        print ('url = ' + product.url)
        print ('caption = ' + product.caption)
        print ('primary_key = ' + product.primary_key)

if __name__ == "__main__":
    main()