#!/usr/bin/env node

// Keep npm from applying its implicit `node-gyp rebuild` fallback when a
// package contains binding.gyp but no install script. Published consumers load
// native artifacts from optional platform packages instead.
console.log('doe-gpu: install complete; native artifacts are resolved at runtime');
