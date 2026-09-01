# Gemma 270M Electron qualification oracle

The W0 and D0 lanes load the same hash-bound Q4 manifest, tokenizer, prompt,
shader set, Electron main-process application, and sampling contract. Each lane
must execute the requested prefill and every requested decode step on the
declared physical AMD Vulkan tuple without provider substitution.

The blocking numerical oracle compares every captured logits vector with the
declared absolute-or-relative tolerance and requires identical selected token
IDs. KV evidence must cover real cache buffers with a positive sequence length
and at least one key or value digest that differs from an all-zero buffer of the
same length. Promotion additionally requires checkpoint coverage for embedding,
RMSNorm, QKV, RoPE, attention, KV, MLP, and logits. Text readability is not an
oracle.
