function parseOracle(stdout) {
  const prefix = 'DOE_CPP_ML_ORACLE=';
  const line = Buffer.from(stdout).toString('utf8')
    .split('\n')
    .find((candidate) => candidate.startsWith(prefix));
  if (!line) throw new Error('cpp-ml process did not emit its oracle marker');
  return JSON.parse(line.slice(prefix.length));
}

function comparableIdentity(result) {
  return {
    oraclePass: result.oraclePass,
    cases: result.cases.map((item) => ({
      expectedDigit: item.expectedDigit,
      gpuDigit: item.gpuDigit,
      cpuDigit: item.cpuDigit,
      inputMaxAbsError: item.inputMaxAbsError,
      hiddenMaxAbsError: item.hiddenMaxAbsError,
      outputMaxAbsError: item.outputMaxAbsError,
      gpuOutput: item.gpuOutput,
      cpuOutput: item.cpuOutput,
    })),
  };
}

export function evaluate({ stdout }) {
  const result = parseOracle(stdout);
  if (result.oraclePass !== true) throw new Error('cpp-ml staged oracle failed');
  return {
    output: JSON.stringify(comparableIdentity(result)),
    providerIdentity: result.provider,
    evidence: result,
  };
}
