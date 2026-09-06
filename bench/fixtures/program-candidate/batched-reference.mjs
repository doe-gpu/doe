// Reuse the single-query reference for a declared batch of search queries.
import { compute as distance } from './reference.mjs';

function compute(inputs) {
  const [rows, dimensions, queries] = new Uint32Array(inputs.parameters.buffer);
  const output = new Float64Array(rows * queries);
  const queryBytes = dimensions * Float32Array.BYTES_PER_ELEMENT;
  for (let query = 0; query < queries; query += 1) {
    output.set(distance({ ...inputs,
      query: inputs.query.slice(query * queryBytes, (query + 1) * queryBytes),
    }), query * rows);
  }
  return output;
}

export { compute };
