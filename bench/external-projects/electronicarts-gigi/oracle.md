# Gigi generated WebGPU oracle

The pinned Gigi suite is its own upstream oracle. Each generated `index.js`
executes one generated technique, waits for submitted GPU work, reads results
back, and invokes validation code from `UnitTestLogic.js`. Texture cases compare
against pinned `_GoldImages_WebGPU` PNG files; buffer cases compare typed values
or bytes. A thrown mismatch or nonzero process result is a failure.

The checked-in Doe runner corrects two orchestration bugs without changing any
Gigi workload: upstream `RunTests.py` passes `"node ."` as one executable name
on POSIX and does not exit nonzero when cases fail. Doe enumerates the same
generated `index.js` cases, runs `node .` in each original directory, and makes
each process result visible in the raw matrix.

Gold-image differences produced by Dawn on the diagnostic software renderer
remain oracle failures. They must not be converted into Doe passes or used for
physical-GPU performance claims.
