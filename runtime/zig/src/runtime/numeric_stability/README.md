Experimental numeric-stability subsystem.

This subtree contains non-core runtime logic for numeric-stability capture,
evaluation, decode replay, policy loading, and receipt emission.

Compatibility wrappers remain at the historical `runtime/zig/src/*` paths so
the rest of Doe can continue to import the subsystem while cleanup proceeds.
