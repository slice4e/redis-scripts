# Redis Vector Database Benchmark

This project provides a comprehensive benchmarking framework for Redis vector databases, supporting both RediSearch and Redis Enterprise configurations with HNSW (Hierarchical Navigable Small World) algorithm optimization.

## Overview

The Redis Vector Database Benchmark is designed to evaluate the performance of vector similarity search operations using Redis as the backend. It supports various dataset sizes, cluster configurations, and performance monitoring tools to provide detailed insights into Redis vector database performance.

## Features

- **Multiple Dataset Support**: Test with datasets ranging from 1M to 400M vectors
- **Flexible NUMA Configuration**: Optimize performance with custom NUMA settings
- **Cluster Support**: Benchmark both single-instance and clustered Redis deployments
- **Redis Enterprise Support**: Test with Redis Enterprise for production-scale scenarios
- **Performance Monitoring**: Integrated EMON monitoring for detailed performance analysis
- **Remote Deployment**: Support for multi-server benchmark configurations

## Quick Start

1. **Configure the benchmark**:
   ```bash
   cp config.file.template config.file
   # Edit config.file with your specific settings
   ```

2. **Run the benchmark**:
   ```bash
   ./run-vector-db-benchmark.sh config.file
   ```

## Configuration

The main configuration is done through `config.file`. Key sections include:

- **Redis Server Settings**: Redis path, version, NUMA configuration
- **Cluster Configuration**: Multi-node setup and replica settings  
- **Benchmark Settings**: Dataset selection, query parameters, index configuration
- **Performance Monitoring**: EMON and profiling options

## Python Environment Management

The benchmark system uses a Python virtual environment for dependencies. You can manage it using `benchmark_utils.sh`:

### Setup Complete Environment
```bash
./benchmark_utils.sh --setup    # Setup benchmark environment (default)
./benchmark_utils.sh            # Same as above
```

### Activate Virtual Environment Only
```bash
# Method 1 (recommended - sources in current shell)
source <(./benchmark_utils.sh --activate-venv)

# Method 2 (shows activation command)
./benchmark_utils.sh --activate-venv
```

## Custom Configuration Generator

For advanced users who need to create custom benchmark configurations with specific HNSW parameters, use the standalone `create_custom_config.sh` script:

```bash
# Create a custom configuration with specific parameters
./create_custom_config.sh -m 64 -e 512 -s "90,100,110" -p 16 -o my-config.json

# Use vectorsets instead of redisearch
./create_custom_config.sh --vector-search vectorsets --data-type FLOAT32

# Generate configuration for multiple EF_SEARCH values
./create_custom_config.sh --ef-search "64,128,256" --parallel 32
```

**Available Options:**
- `-m, --m VALUE`: HNSW M parameter (1-512, default: 32)
- `-e, --ef-construction VALUE`: EF_CONSTRUCTION parameter (1-2048, default: 256) 
- `-s, --ef-search VALUES`: EF_SEARCH values, comma-separated (default: 128)
- `-p, --parallel VALUE`: Number of parallel clients (1-1024, default: 8)
- `-t, --data-type TYPE`: Data type FLOAT16|FLOAT32 (default: FLOAT16)
- `-v, --vector-search TYPE`: Vector search type redisearch|vectorsets (default: redisearch)
- `-o, --output FILE`: Output configuration file (default: redis-custom.json)

The generated configuration files are compatible with the vector-db-benchmark framework and can be used directly for benchmarking.

## General Benchmarking Methodology

### Performance Guidelines

Redis recommends about **25 GB of data per shard** to satisfy performance and high-availability requirements. Each shard can utilize at most **REDISEARCH_WORKERS=16** parallel workers.

### Example Configurations

#### Example 1: Saturate 128 vCPUs
To saturate 128 vCPUs, we need REDISEARCH_WORKERS=16 and 8 shards. 
- Since we expect about 25GB of data per shard, we need about 200GB of data
- Since we consume approximately 6GB of memory capacity per M vectors, we need at least 33M vectors
- The closest vector-db-benchmark supports is 40M vectors
- **Configuration**: 8 shards, 16 workers per shard, 40M vectors

#### Example 2: Benchmark a large dataset with 200M vectors
- 200M vectors consume approximately 1.2TB of data (6GB per M vectors)
- Since Redis recommends about 25GB per shard, we need to create 48 shards
- For best performance, we can utilize REDISEARCH_WORKERS=16 per shard
- **Requirements**: 16 workers × 48 shards = 768 vCPUs
- **Deployment**: Could utilize a cluster of 4 machines with 192 vCPUs each

### Performance Comparison Notes

When comparing performance results (RPS), ensure comparisons are made at the same precision level. When increasing the number of shards, precision will increase since each shard responds with top K results.

## HNSW Algorithm Parameters

### Key Parameters

- **EF_SEARCH**: Controls the number of edges explored by the algorithm in every level of the graph
  - Higher ef_search = more graph exploration = better precision but slower search time
  - Used during search operations to balance precision vs performance

- **M**: Number of maximum allowed outgoing edges for each node in the graph
  - On layer zero, the maximal number of outgoing edges will be 2M
  - Affects index build time and search performance

- **EF_CONSTRUCTION**: Number of maximum allowed potential outgoing edges candidates during graph building
  - Higher values = better index quality but slower build time

### Search Process

1. **Vector-db-benchmark** sets 'K' parameter to the number of searched nearest neighbors during ground-truth generation
2. In our setup, K=100, so HNSW returns 100 approximate nearest neighbors
3. **Precision Calculation**: Compares returned vectors from HNSW search with ground-truth generation results

### Cluster Search Behavior

When splitting the graph into multiple shards (cluster nodes):
1. Each shard is searched for the 100 nearest neighbors
2. A reduce step aggregates results from all shards
3. Final response contains 100 neighbors from the combined results
4. **Performance Impact**: Sharding increases work per query but improves precision by examining more of the graph

## Available Datasets

- laion-512-1M, laion-512-10M, laion-512-20M, laion-512-40M
- laion-512-100M, laion-512-200M, laion-512-400M
- laion-768-1M, dbpedia-1536-1M, cohere-768-1M

**Memory Requirements**: Approximately 6GB of memory capacity per M vectors.

## Supported Index Combinations

Available M and EF_CONSTRUCTION combinations:
- M16 EF128, M32 EF128, M32 EF256, M32 EF512, M64 EF256, M64 EF512

## Requirements

- Redis (version 8.0+ recommended)
- Python 3.x with virtual environment support
- numactl (for NUMA optimization)
- SSH access for remote deployments
- EMON (optional, for performance monitoring)

## File Structure

```
├── config.file.template          # Configuration template
├── run-vector-db-benchmark.sh     # Main benchmark script
├── redis_utils.sh                # Redis setup utilities
├── benchmark_utils.sh             # Benchmark utilities
├── config_loader.sh               # Configuration management
├── common_utils.sh                # Shared utilities
└── README.md                     # This file
```

