# Vector similarity research scripts

This directory contains scripts for:
- Downloading image embeddings, text embedding and metadata from [LAION](https://laion.ai/blog/laion-400-open-dataset/) 400M dataset
- Uploading the data to Redis server, and indexing it
- Running text/image queries

Purpose of this scripts are to check how vector similarity in Redis works. See how to benchmark vector similarity with Redis and LAION dataset [here](#benchmarking-redis-vector-similarity-with-laion-dataset)

### Downloading data
To download data simply run `download_data.sh` script. Script will ask how many files you want to download by asking for first and last file index. Each file from LAION dataset contains 1 000 448 items and embeddings are 512 dimensions vectors.

### Uploading and indexing data
First run redis instance with RediSearch module loaded. You can run it by using command: `redis-server --loadmodule {redisearch_path}`

If you want to use redis cluster you can use script `run_redis_cluster.sh` for creating redis cluster on localhost:

`REDIS_DIR={redis_dir} CLUSTER_PATH=${cluster_path} REDISEARCH_PATH=${redisearch_path} run_redis_cluster.sh {node_number} {port_number}`

| Variable  | Description |
| ------------- | ------------- |
| redis_dir  | Absolute path to the main redis directory  |
| cluster_path  | Absolute path to folder where cluster nodes will store config, logs and rdb files  |
| redisearch_path  | Absolute path to redisearch.so file (keep in mind that to use redisearch with Redis Cluster you need to use `make build COORD=oss MT=1` to build it)  |
| node_number  | Number of nodes that will be created in cluster |
| port_number  | Port that first instance of redis cluster will be listening on (f.e. if port_number==8000 and node_number==6, ports 8000, 8001, 8002, 8003, 8004, 8005 will be used) |

Next step is to run `prepare_data.py` script.
```
python prepare_data.py --help
usage: prepare_data.py [-h] --data-dir DATA_DIR [--hnsw-index] [--no-index] [--no-upload] [--redis-port PORT] [--img-emb] [--no-text-emb] [--cluster]

options:
  -h, --help            show this help message and exit
  --data-dir DATA_DIR   Path to the data directory
  --hnsw-index          Create hnsw index instead of flat
  --no-index            Don't create index, just load the data to redis server
  --no-upload           Don't upload the data, just create search index
  --redis-port PORT, -p PORT
                        Port of redis server
  --img-emb             Use if image embeddings are to be included in hash
  --no-text-emb         Use if text embeddings are not to be included in hash
  --cluster             Connect to redis cluster instead of redis server
```
By default running `python prepare_data.py --data_dir {DATA_DIR}` script will try to connect to redis-server on port 6379 upload only all text embeddings that are located in `{DATA_DIR}` directory and create FLAT index. 

! Important ! Running `prepare_data.py` will flush current data from Redis database before uploading new data !

Examples of using `prepare_data.py` script:

`python prepare_data.py --data_dir /home/redis/laion --hnsw-index --redis-port 12000 --img-emb` - this command will upload both image and text embeddings from /home/redis/laion directory into the Redis database located on port 12000 and it will create HNSW index for the data.

`python prepare_data.py --data_dir /home/redis/laion --redis-port 12000 --img-emb --no-text-emb --cluster` - this command will upload only image embeddings from /home/redis/laion directory into the Redis cluster that one of nodes is located on port 12000 and it will create FLAT index for the data.

### Running queries
To run text queries use `run_text_query.py` script:
```
python run_text_query.py --help
usage: run_text_query.py [-h] [--redis-port PORT] [--query QUERY] [--cluster]

options:
  -h, --help            show this help message and exit
  --redis-port PORT, -p PORT
                        Port of redis server
  --query QUERY         Query to run vecsim search on
  --cluster             Connect to redis cluster instead of redis server
```
This script will return 5 items from the Redis database that have the best similarity score between provided `{QUERY}` and text embeddings.

To run image queries you need to first prepare image embedding file for the image that you want to query the database with. You can do that by using img2dataset and [clip-retrieval](https://github.com/rom1504/clip-retrieval) and following these steps:
```
echo https://upload.wikimedia.org/wikipedia/commons/thumb/7/7e/PS4-Console-wDS4.jpg/2560px-PS4-Console-wDS4.jpg >> myimglist.txt
img2dataset --url_list=myimglist.txt --output_folder=query_img_folder --thread_count=64 --image_size=256
clip-retrieval inference --input_dataset query_img_folder --output_folder embeddings_folder
```
This will create `img_emb_1.npy` file inside `embeddings_folder/img_emb/` directory which is used to query against the database. To run it as a query use `run_img_query.py` script which works similar to the `run_text_query.py` script:
```
python run_img_query.py --help
usage: run_img_query.py [-h] [--redis-port PORT] --query-file QUERY_FILE [--cluster]

options:
  -h, --help            show this help message and exit
  --redis-port PORT, -p PORT
                        Port of redis server
  --query-file QUERY_FILE
                        Path to file with image query embedding to run vecsim search on
  --cluster             Connect to redis cluster instead of redis server
```
This script will return 5 items from the Redis database that have the best similarity score between provided image embedding from {QUERY_FILE} and image embeddings in database.

# Benchmarking Redis Vector Similarity with LAION dataset
To run vector similarity benchmark on Redis database we use Redis fork of [vector-db-benchmark](https://github.com/redis-performance/vector-db-benchmark):
```
git clone https://github.com/redis-performance/vector-db-benchmark
cd vector-db-benchmark
git checkout update.redisearch
```
`datasets/datasets.json` file contains available datasets for benchmarking

`experiments/configurations/redis-single-node.json` file contains available benchmark scenarios for Redis

To run benchmark use command:
`REDIS_PORT={redis_port} python run.py --engines {scenario} --datasets {dataset} --host {host_ip}` f.e.:

`REDIS_PORT=6379  python3 run.py --engines redis-m-16-ef-128 --datasets laion-img-emb-512-1M --host localhost`

Benchmarking engine will store results files in json format in `results` directory. Each search configuration defined in benchmark scenario will have separate result file with these metrics:
  -  total_time
  -  mean_time
  -  mean_precisions
  -  std_time
  -  min_time
  -  max_time
  -  rps
  -  p50_time
  -  p95_time
  -  p99_time