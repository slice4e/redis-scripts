import numpy as np
from redis.commands.search.query import Query
from redis import Redis
from sentence_transformers import SentenceTransformer

TEXT_ITEM_KEYWORD_EMBEDDING_FIELD='text_item_emb_vector'

host = 'localhost'
port = 5000
redis_conn = Redis(host=host, port=port)
print(redis_conn.ping())
print("Connected to Redis")

model = SentenceTransformer('sentence-transformers/clip-ViT-B-32-multilingual-v1')

topK=5
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