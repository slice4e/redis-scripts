# To run this script you need to first create numpy file with image embeddings. 
# You can do that by using img2dataset and clip-retrieval (https://github.com/rom1504/clip-retrieval)
# Short example how to use it:
#  echo http://ecx.images-amazon.com/images/I/31Iq1gu7aVL._SL500_SS160_.jpg >> myimglist.txt
#  echo https://upload.wikimedia.org/wikipedia/commons/thumb/7/7e/PS4-Console-wDS4.jpg/2560px-PS4-Console-wDS4.jpg >> myimglist.txt
#  img2dataset --url_list=myimglist.txt --output_folder=query_img_folder --thread_count=64 --image_size=256
#  clip-retrieval inference --input_dataset query_img_folder --output_folder embeddings_folder

import numpy as np
import argparse
from time import time
from redis.commands.search.query import Query
from redis import Redis

def parse_cmd_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--redis-port", "-p", dest="port", type=str, default="5000", help="Port of redis server")
    parser.add_argument("--query-file", type=str, required=True, help="Path to file with image query embedding to run vecsim search on")
    args = parser.parse_args()
    return args

def main():
    args = parse_cmd_args()

    IMG_ITEM_EMBEDDING_FIELD = 'img_item_emb_vector'

    host = 'localhost'
    port = args.port
    redis_conn = Redis(host=host, port=port)
    print(redis_conn.ping())
    print("Connected to Redis")

    topK=5

    #vectorize the query
    query_data = np.load(args.query_file)
    
    for vector in query_data:
        query_vector = vector.astype(np.float32).tobytes()

        #prepare the query
        q = Query(f'*=>[KNN {topK} @{IMG_ITEM_EMBEDDING_FIELD} $vec_param AS vector_score]').sort_by('vector_score').paging(0,topK).return_fields('url','caption','primary_key').dialect(2)
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
