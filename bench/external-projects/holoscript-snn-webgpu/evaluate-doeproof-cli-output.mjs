function comparableIdentity(result) {
  return {
    shader: result?.shader ?? null,
    dispatch: result?.dispatch ?? null,
    synchronization: result?.synchronization ?? null,
    readback: result?.readback ?? null,
    oracle: result?.oracle ?? null,
    topologies: (result?.topologies ?? []).map((topology) => ({
      id: topology.id,
      nnz: topology.nnz,
      oracleHash: topology.oracleHash,
      outputHash: topology.outputHash,
    })),
  };
}

export function evaluate({ stdout }) {
  const result = JSON.parse(Buffer.from(stdout).toString('utf8').trim().split('\n').at(-1));
  return {
    output: JSON.stringify(comparableIdentity(result)),
    providerIdentity: result?.provider?.doeProof,
    evidence: result,
  };
}
