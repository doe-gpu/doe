# CTS Subset Report

- Generated: `2026-08-10T23:00:41.701519Z`
- Config: `bench/fixtures/cts_subset.fawn-node.json`
- Workdir: `/home/x/deco/doe/bench/vendor/dawn/third_party/webgpu-cts`
- Command template: `node tools/run_node --quiet --gpu-provider {repo_root}/bench/cts/fawn-node-gpu-provider.cjs {query}`
- Adapter identity bound: `True`

- Query count: `12`
- Pass count: `12`
- Fail count: `0`
- Requirements: `Install vendored CTS dependencies first: cd bench/vendor/dawn/third_party/webgpu-cts && npm install`

| Bucket | Queries | Pass | Fail |
|---|---:|---:|---:|
| `adapter` | 2 | 2 | 0 |
| `buffer` | 2 | 2 | 0 |
| `command_buffer` | 2 | 2 | 0 |
| `queue` | 2 | 2 | 0 |
| `compute` | 1 | 1 | 0 |
| `validation` | 2 | 2 | 0 |
| `shader_execution` | 1 | 1 | 0 |

| Id | Bucket | Query | Exit | Wall ms | Pass |
|---|---|---|---:|---:|---:|
| `adapter_request` | `adapter` | `webgpu:api,operation,adapter,requestAdapter:*` | 0 | 1052.1731389453635 | True |
| `adapter_request_device` | `adapter` | `webgpu:api,operation,adapter,requestDevice:*` | 0 | 4792.934753000736 | True |
| `buffer_map` | `buffer` | `webgpu:api,operation,buffers,map:*` | 0 | 1542.0058600138873 | True |
| `buffer_bind_group` | `buffer` | `webgpu:api,operation,buffers,createBindGroup:*` | 0 | 1248.5269969329238 | True |
| `command_buffer_basic` | `command_buffer` | `webgpu:api,operation,command_buffer,basic:*` | 0 | 1256.8394760601223 | True |
| `command_copy_buffer_to_buffer` | `command_buffer` | `webgpu:api,operation,command_buffer,copyBufferToBuffer:*` | 0 | 1305.134855909273 | True |
| `queue_write_buffer` | `queue` | `webgpu:api,operation,queue,writeBuffer:*` | 0 | 1267.3736939905211 | True |
| `queue_on_submitted_work_done` | `queue` | `webgpu:api,operation,onSubmittedWorkDone:*` | 0 | 1248.4867119928822 | True |
| `compute_basic` | `compute` | `webgpu:api,operation,compute,basic:*` | 0 | 24594.61673197802 | True |
| `validation_error_scope` | `validation` | `webgpu:api,validation,error_scope:*` | 0 | 1167.075271019712 | True |
| `validation_buffer_create` | `validation` | `webgpu:api,validation,buffer,create:*` | 0 | 1295.3196680173278 | True |
| `shader_texture_dimensions` | `shader_execution` | `webgpu:shader,execution,expression,call,builtin,textureDimensions:*` | 0 | 24741.652533994056 | True |

