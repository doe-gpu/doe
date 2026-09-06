// Trusted reference: one squared Euclidean distance per database vector.
function compute(inputs) {
  const database = new Float32Array(inputs.database.buffer);
  const query = new Float32Array(inputs.query.buffer);
  const parameters = new Uint32Array(inputs.parameters.buffer);
  const [rows, dimensions] = parameters;
  const output = new Float64Array(rows);
  for (let row = 0; row < rows; row += 1) {
    let distance = 0;
    for (let column = 0; column < dimensions; column += 1) {
      const difference = database[row * dimensions + column] - query[column];
      distance += difference * difference;
    }
    output[row] = distance;
  }
  return output;
}

export { compute };
