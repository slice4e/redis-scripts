# Migration Guide: Unified Redis Setup

## Summary of Changes

The three separate scripts (`local.sh`, `remote.sh`, `remote_multiple_servers.sh`) have been unified into a single `redis_setup.sh` script that handles all deployment scenarios.

## Benefits of the Unified Approach

1. **Reduced Code Duplication**: Eliminates ~80% of duplicated code across the three scripts
2. **Easier Maintenance**: Single script to update when making changes
3. **Consistent Behavior**: Same logic applied across all deployment types
4. **Better Error Handling**: Centralized error handling and logging
5. **Improved Non-Root Support**: Better handling of permission issues

## Key Features of the New Script

### Modular Functions
- `execute_command()`: Handles local vs remote command execution
- `execute_command_background()`: For background processes (server startup)
- `copy_file_to_server()`: File transfer abstraction
- `install_dependencies()`: System dependency installation
- `setup_redis()`: Redis installation and compilation
- `setup_redisearch()`: RediSearch module setup
- `cleanup_redis()`: Redis cleanup operations
- `start_redis_server()`: Server startup
- `create_redis_cluster()`: Cluster creation

### Automatic Detection
The script automatically determines the deployment type based on configuration variables:
- `SERVER_REMOTE`: true/false
- `CLUSTER_MULTIPLE_SERVERS`: 1/0
- `REDIS_CLUSTER`: 1/0

## Configuration Variables Used

The unified script uses these existing configuration variables:
- `SKIP_SETUP`: Skip the entire setup process
- `SERVER_REMOTE`: Whether servers are remote
- `CLUSTER_MULTIPLE_SERVERS`: Multiple server cluster setup
- `CLUSTER_SERVERS[]`: Array of cluster server IPs
- `TARGET`: Target server IP
- `REDIS_PATH`: Redis installation path
- `REDIS_BRANCH`: Redis branch to use
- `REDISEARCH_PATH`: RediSearch path (for multiple servers)
- `REDISEARCH_BRANCH`: RediSearch branch
- `VECTOR_SEARCH`: Type of vector search (redisearch/vectorsets)
- `USE_NUMACTL`: Enable NUMA control
- `NUMA_NODES`: NUMA node specification
- `PORT`: Redis port
- `REDIS_CLUSTER`: Enable Redis cluster mode
- All SSH-related variables

## Backward Compatibility

The changes are backward compatible:
1. The main script (`run-vector-db-benchmark.sh`) has been updated to use the new unified script
2. Old scripts (`local.sh`, `remote.sh`, `remote_multiple_servers.sh`) can be kept for reference or removed
3. All existing configuration files continue to work without changes

## Testing Recommendations

1. **Local Setup**: Test with `SERVER_REMOTE=false`
2. **Single Remote Server**: Test with `SERVER_REMOTE=true` and `CLUSTER_MULTIPLE_SERVERS=0`
3. **Multiple Remote Servers**: Test with `SERVER_REMOTE=true` and `CLUSTER_MULTIPLE_SERVERS=1`
4. **Cluster vs Standalone**: Test both `REDIS_CLUSTER=1` and `REDIS_CLUSTER=0`

## Rollback Plan

If issues arise, you can easily rollback by:
1. Reverting the changes to `run-vector-db-benchmark.sh`
2. Using the original separate scripts

## File Status After Migration

### New Files
- `redis_setup.sh` - Unified Redis setup script
- `MIGRATION_GUIDE.md` - This guide

### Modified Files
- `run-vector-db-benchmark.sh` - Updated to use unified script

### Unchanged Files (can be removed after testing)
- `local.sh` - Original local setup script
- `remote.sh` - Original remote setup script  
- `remote_multiple_servers.sh` - Original multiple servers script

## Error Handling Improvements

The new script includes better error handling for:
- Non-root execution (warns about numactl instead of failing)
- SSH connection issues
- Missing directories or files
- Build failures

## Future Enhancements

The unified structure makes it easier to add:
- Docker support
- Kubernetes deployment
- Additional Redis modules
- Better logging and monitoring
- Configuration validation
