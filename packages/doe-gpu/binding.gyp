{
  "targets": [
    {
      "target_name": "doe_napi",
      "sources": [
        "../../runtime/bridge/webgpu-addon/doe_napi_globals.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_helpers.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_instance.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_buffer.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_shader.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_pipeline.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_queue.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_formats.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_render.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_caps.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_program.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_nd_infra.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_nd_stubs.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_nd_immediates.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_nd_device.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_nd_encoder.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_nd_creators.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_surface.c",
        "../../runtime/bridge/webgpu-addon/doe_napi_init.c"
      ],
      "include_dirs": [],
      "defines": ["NAPI_VERSION=8"],
      "conditions": [
        [
          "OS=='mac'",
          {
            "xcode_settings": {
              "OTHER_CFLAGS": ["-std=c11"],
              "MACOSX_DEPLOYMENT_TARGET": "13.0"
            }
          }
        ],
        [
          "OS=='linux'",
          {
            "cflags": ["-std=c11"]
          }
        ]
      ]
    }
  ]
}
