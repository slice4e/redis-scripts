# redis-scripts

Repository of helper scripts indended to faciliate Redis benchmarking and telemetry collection. Scripts in benchmark-spec/ facilitate executing the Redis regression suite: https://github.com/redis/redis-benchmarks-specification . Scripts in single-node/ faciliate quick benchmarking of Redis on a single-node using memtier benchmark. 


## Versioning

Releases are tagged `vX.Y.Z` in git ([semantic versioning](https://semver.org)):

- **MAJOR**: a change that alters results or breaks existing configs (e.g. renamed/removed config keys, different default placement or tuning).
- **MINOR**: new features or config options that are backward compatible.
- **PATCH**: bug fixes that do not change how results are measured.

To use a release: `git checkout v1.0.0`. To see which version you have: `git describe --tags`. Report this version with your results.

## Usage

Copy the template config file to create your own. 
Then execute: ./run_all.sh  [my_config_file]  


## Best Known Methods (BKMs) 

### Using localhost vs. physical interface, when benchmarking on a local server: 
When communitcating to Redis on a single server, we can use localhost/127.0.0.1 or a physical network interface with an IP address. This choice can lead to different behaviour (performance and cpu utilization). For consistent results it is better NOT to use localhost. Use the physical interface so that we can pin the IRQ interrupts and prevent the OS from servicing them from a remote socket. In addition the software stack (kernel time) is different when using the physical interface and closer to a real-world scenario. We have observed better performance when the IRQs are pinned to the same socket as the redis server. When using the physical interface, EMON will still report 0 MB/s IO bandwidth and performance is not limited by the available bandwidth on the physical NIC. 
