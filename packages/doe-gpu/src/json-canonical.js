// Preserve Doe's existing recursive JSON key order without changing hash formats.
function sortedJsonValue(value) {
  if (Array.isArray(value)) return value.map(sortedJsonValue);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort()
      .map((key) => [key, sortedJsonValue(value[key])]));
  }
  return value;
}

export { sortedJsonValue };
