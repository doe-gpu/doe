// Runtime validators for schema-backed plan contracts.

import {
  DOE_CAPTURE_GRAPH_ARRAY_FIELDS,
  DOE_CAPTURE_GRAPH_FIELDS,
  DOE_COMMAND_STREAM_KIND,
  DOE_NORMALIZED_PLAN_FIELDS,
  DOE_NORMALIZED_PLAN_REQUIRED_FIELDS,
  DOE_NORMALIZED_PLAN_SCHEMA_VERSION,
  DOE_PLAN_ARTIFACT_CONTRACTS,
  DOE_PLAN_ARTIFACT_KINDS,
  DOE_PLAN_SCHEMA_VERSIONS,
  DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND,
  DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION,
} from './plan-contracts.js';

function isObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function describeReceived(value) {
  if (value === null) return 'null';
  if (Array.isArray(value)) return 'array';
  return typeof value;
}

function pushError(errors, code, path, message, expected, received) {
  errors.push({
    code,
    path,
    message,
    expected,
    received: describeReceived(received),
  });
}

function requireObject(errors, value, path, label) {
  if (isObject(value)) return true;
  pushError(errors, 'type_mismatch', path, `${label} must be an object`, 'object', value);
  return false;
}

function requireNonEmptyString(errors, value, path) {
  if (typeof value === 'string' && value.length > 0) return;
  pushError(errors, 'type_mismatch', path, 'must be a non-empty string', 'non-empty string', value);
}

function requireNonNegativeInteger(errors, value, path) {
  if (Number.isInteger(value) && value >= 0) return;
  pushError(errors, 'type_mismatch', path, 'must be a non-negative integer', 'integer >= 0', value);
}

function requirePositiveInteger(errors, value, path) {
  if (Number.isInteger(value) && value >= 1) return;
  pushError(errors, 'type_mismatch', path, 'must be a positive integer', 'integer >= 1', value);
}

function requireSha256(errors, value, path) {
  if (typeof value === 'string' && /^[0-9a-f]{64}$/u.test(value)) return;
  pushError(errors, 'pattern_mismatch', path, 'must be a lowercase SHA-256', '^[0-9a-f]{64}$', value);
}

function rejectUnknownFields(errors, value, allowed, path) {
  const allowedSet = new Set(allowed);
  for (const field of Object.keys(value)) {
    if (!allowedSet.has(field)) {
      pushError(
        errors,
        'unknown_field',
        `${path}.${field}`,
        'field is not allowed by the schema',
        `one of: ${allowed.join(', ')}`,
        value[field],
      );
    }
  }
}

function validateSchemaType(errors, value, expected, path) {
  const valid = (
    (expected === 'array' && Array.isArray(value))
    || (expected === 'object' && isObject(value))
    || (expected === 'integer' && Number.isInteger(value))
    || (expected === 'string' && typeof value === 'string')
  );
  if (!valid) {
    pushError(errors, 'type_mismatch', path, `must be ${expected}`, expected, value);
  } else if (expected === 'string' && value.length === 0) {
    pushError(errors, 'type_mismatch', path, 'must be a non-empty string', 'non-empty string', value);
  }
}

function validateCommand(command, index, errors) {
  const path = `commands[${index}]`;
  if (!requireObject(errors, command, path, 'command')) return;
  requireNonEmptyString(errors, command.kind, `${path}.kind`);
}

function validateCaptureRecord(record, path, errors) {
  if (!requireObject(errors, record, path, 'capture record')) return;
  requirePositiveInteger(errors, record.id, `${path}.id`);
}

function validateCaptureRecordArray(graph, field, errors) {
  if (!Array.isArray(graph[field])) {
    pushError(errors, 'type_mismatch', `artifact.${field}`, `${field} must be an array`, 'array', graph[field]);
    return;
  }
  graph[field].forEach((record, index) => {
    const path = `artifact.${field}[${index}]`;
    validateCaptureRecord(record, path, errors);
    if (!isObject(record)) return;
    if (field === 'buffers') {
      for (const required of ['descriptor', 'mappedAtCreation', 'size', 'usage']) {
        if (!(required in record)) {
          pushError(errors, 'required_field', `${path}.${required}`, 'required field is missing', 'present', undefined);
        }
      }
      requireObject(errors, record.descriptor, `${path}.descriptor`, 'buffer descriptor');
      requireNonNegativeInteger(errors, record.size, `${path}.size`);
      requireNonNegativeInteger(errors, record.usage, `${path}.usage`);
      if (typeof record.mappedAtCreation !== 'boolean') {
        pushError(errors, 'type_mismatch', `${path}.mappedAtCreation`, 'must be a boolean', 'boolean', record.mappedAtCreation);
      }
    } else if (field === 'bufferWrites') {
      for (const required of ['buffer', 'bufferOffset', 'byteLength', 'dataSha256']) {
        if (!(required in record)) {
          pushError(errors, 'required_field', `${path}.${required}`, 'required field is missing', 'present', undefined);
        }
      }
      requirePositiveInteger(errors, record.buffer, `${path}.buffer`);
      requireNonNegativeInteger(errors, record.bufferOffset, `${path}.bufferOffset`);
      requireNonNegativeInteger(errors, record.byteLength, `${path}.byteLength`);
      requireSha256(errors, record.dataSha256, `${path}.dataSha256`);
    } else if (field === 'shaderModules') {
      requireNonEmptyString(errors, record.code, `${path}.code`);
      requireSha256(errors, record.wgslSha256, `${path}.wgslSha256`);
    } else if (field === 'computePipelines') {
      requirePositiveInteger(errors, record.module, `${path}.module`);
      requireNonEmptyString(errors, record.entryPoint, `${path}.entryPoint`);
    } else if (field === 'commandBuffers') {
      requirePositiveInteger(errors, record.encoder, `${path}.encoder`);
      if (!Array.isArray(record.commands)) {
        pushError(errors, 'type_mismatch', `${path}.commands`, 'must be an array', 'array', record.commands);
      } else {
        record.commands.forEach((command, commandIndex) => {
          requireObject(errors, command, `${path}.commands[${commandIndex}]`, 'command');
        });
      }
    } else if (field === 'submissions') {
      if (!Array.isArray(record.commandBuffers)) {
        pushError(errors, 'type_mismatch', `${path}.commandBuffers`, 'must be an array', 'array', record.commandBuffers);
      } else {
        record.commandBuffers.forEach((id, idIndex) => {
          requirePositiveInteger(errors, id, `${path}.commandBuffers[${idIndex}]`);
        });
      }
    }
  });
}

function validateRequiredStringArray(graph, field, requiredValue, errors) {
  const value = graph[field];
  const path = `artifact.${field}`;
  if (!Array.isArray(value)) {
    pushError(errors, 'type_mismatch', path, `${field} must be an array`, 'array', value);
    return;
  }
  if (value.length === 0) {
    pushError(errors, 'min_items', path, 'must contain at least one item', 'at least 1 item', value);
  }
  value.forEach((item, index) => requireNonEmptyString(errors, item, `${path}[${index}]`));
  if (!value.includes(requiredValue)) {
    pushError(errors, 'contains_mismatch', path, `must contain ${requiredValue}`, requiredValue, value);
  }
}

function validationError(prefix, result) {
  const first = result.errors[0];
  const error = new Error(`${prefix}: ${first.path} ${first.message}`);
  Object.assign(error, first);
  return error;
}

export function validateCommandStream(commands) {
  const errors = [];
  if (!Array.isArray(commands)) {
    pushError(errors, 'type_mismatch', 'commands', 'command stream must be an array', 'array', commands);
  } else {
    commands.forEach((command, index) => validateCommand(command, index, errors));
  }
  return {
    ok: errors.length === 0,
    kind: DOE_COMMAND_STREAM_KIND,
    commandCount: Array.isArray(commands) ? commands.length : 0,
    errors,
  };
}

export function assertCommandStream(commands) {
  const result = validateCommandStream(commands);
  if (!result.ok) throw validationError('Invalid Doe command stream', result);
  return commands;
}

export function validateNormalizedPlan(plan) {
  const errors = [];
  if (requireObject(errors, plan, 'plan', 'normalized plan')) {
    rejectUnknownFields(errors, plan, DOE_NORMALIZED_PLAN_FIELDS, 'plan');
    for (const field of DOE_NORMALIZED_PLAN_REQUIRED_FIELDS) {
      if (!(field in plan)) {
        pushError(errors, 'required_field', `plan.${field}`, 'required field is missing', 'present', undefined);
      }
    }
    if (plan.schemaVersion !== DOE_NORMALIZED_PLAN_SCHEMA_VERSION) {
      pushError(
        errors,
        'const_mismatch',
        'plan.schemaVersion',
        `schemaVersion must be ${DOE_NORMALIZED_PLAN_SCHEMA_VERSION}`,
        DOE_NORMALIZED_PLAN_SCHEMA_VERSION,
        plan.schemaVersion,
      );
    }
    for (const field of [
      'planKind',
      'workloadId',
      'irPath',
      'irScenario',
      'sourceIrSha256',
      'compatibilityCommandsSha256',
    ]) {
      requireNonEmptyString(errors, plan[field], `plan.${field}`);
    }
    for (const field of ['commandCount', 'bufferWriteCount', 'dispatchCount']) {
      requireNonNegativeInteger(errors, plan[field], `plan.${field}`);
    }
    for (const field of ['planPath', 'commandsPath', 'planSha256']) {
      if (plan[field] !== undefined) requireNonEmptyString(errors, plan[field], `plan.${field}`);
    }
    if (plan.description !== undefined && typeof plan.description !== 'string') {
      pushError(errors, 'type_mismatch', 'plan.description', 'must be a string', 'string', plan.description);
    }
    if (plan.bufferLoadCount !== undefined) {
      requireNonNegativeInteger(errors, plan.bufferLoadCount, 'plan.bufferLoadCount');
    }
    if (plan.matmulGemvVariant !== undefined && plan.matmulGemvVariant !== 'row2_helper_exact') {
      pushError(
        errors,
        'enum_mismatch',
        'plan.matmulGemvVariant',
        'must be row2_helper_exact',
        'row2_helper_exact',
        plan.matmulGemvVariant,
      );
    }
    const commandResult = validateCommandStream(plan.commands);
    if (Array.isArray(plan.commands) && plan.commands.length === 0) {
      pushError(errors, 'min_items', 'plan.commands', 'must contain at least one command', 'at least 1 item', plan.commands);
    }
    for (const error of commandResult.errors) {
      errors.push({ ...error, path: `plan.${error.path}` });
    }
  }
  return {
    ok: errors.length === 0,
    kind: 'doe_normalized_plan',
    schemaVersion: isObject(plan) ? plan.schemaVersion : undefined,
    errors,
  };
}

export function assertNormalizedPlan(plan) {
  const result = validateNormalizedPlan(plan);
  if (!result.ok) throw validationError('Invalid Doe normalized plan', result);
  return plan;
}

export function validateCaptureGraph(graph) {
  const errors = [];
  if (requireObject(errors, graph, 'artifact', 'capture graph')) {
    rejectUnknownFields(errors, graph, DOE_CAPTURE_GRAPH_FIELDS, 'artifact');
    if (graph.schemaVersion !== DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION) {
      pushError(
        errors,
        'const_mismatch',
        'artifact.schemaVersion',
        `schemaVersion must be ${DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION}`,
        DOE_WEBGPU_CAPTURE_GRAPH_SCHEMA_VERSION,
        graph.schemaVersion,
      );
    }
    if (graph.artifactKind !== DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND) {
      pushError(
        errors,
        'const_mismatch',
        'artifact.artifactKind',
        `artifactKind must be ${DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND}`,
        DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND,
        graph.artifactKind,
      );
    }
    if (requireObject(errors, graph.provider, 'artifact.provider', 'provider')) {
      rejectUnknownFields(errors, graph.provider, ['name', 'mode', 'contract'], 'artifact.provider');
      requireNonEmptyString(errors, graph.provider.name, 'artifact.provider.name');
      for (const [field, expected] of [
        ['mode', 'capture'],
        ['contract', 'webgpu-capture-provider'],
      ]) {
        if (graph.provider[field] !== expected) {
          pushError(
            errors,
            'const_mismatch',
            `artifact.provider.${field}`,
            `must be ${expected}`,
            expected,
            graph.provider[field],
          );
        }
      }
    }
    requireObject(errors, graph.metadata, 'artifact.metadata', 'metadata');
    validateRequiredStringArray(
      graph,
      'supportedWebgpuMethods',
      'device.createShaderModule',
      errors,
    );
    validateRequiredStringArray(
      graph,
      'unsupportedCslFeatures',
      'textures',
      errors,
    );
    for (const field of DOE_CAPTURE_GRAPH_ARRAY_FIELDS) {
      if (field === 'supportedWebgpuMethods' || field === 'unsupportedCslFeatures') continue;
      validateCaptureRecordArray(graph, field, errors);
    }
    requireSha256(errors, graph.graphSha256, 'artifact.graphSha256');
  }
  return {
    ok: errors.length === 0,
    artifactKind: isObject(graph) ? graph.artifactKind : undefined,
    schemaVersion: isObject(graph) ? graph.schemaVersion : undefined,
    errors,
  };
}

export function assertCaptureGraph(graph) {
  const result = validateCaptureGraph(graph);
  if (!result.ok) throw validationError('Invalid Doe capture graph', result);
  return graph;
}

export function validatePlanArtifact(artifact) {
  const errors = [];
  if (requireObject(errors, artifact, 'artifact', 'plan artifact')) {
    const expectedVersion = DOE_PLAN_SCHEMA_VERSIONS[artifact.artifactKind];
    if (typeof artifact.artifactKind !== 'string' || expectedVersion == null) {
      pushError(
        errors,
        'enum_mismatch',
        'artifact.artifactKind',
        `artifactKind must be one of: ${DOE_PLAN_ARTIFACT_KINDS.join(', ')}`,
        DOE_PLAN_ARTIFACT_KINDS.join(', '),
        artifact.artifactKind,
      );
    } else if (artifact.schemaVersion !== expectedVersion) {
      pushError(
        errors,
        'const_mismatch',
        'artifact.schemaVersion',
        `schemaVersion must be ${expectedVersion} for ${artifact.artifactKind}`,
        expectedVersion,
        artifact.schemaVersion,
      );
    } else if (artifact.artifactKind === DOE_WEBGPU_CAPTURE_GRAPH_ARTIFACT_KIND) {
      errors.push(...validateCaptureGraph(artifact).errors);
    } else {
      const contract = DOE_PLAN_ARTIFACT_CONTRACTS[artifact.artifactKind];
      for (const field of contract.required) {
        if (!(field in artifact)) {
          pushError(errors, 'required_field', `artifact.${field}`, 'required field is missing', 'present', undefined);
        }
      }
      if (contract.closed) {
        rejectUnknownFields(errors, artifact, contract.fields, 'artifact');
      }
      for (const [field, expected] of Object.entries(contract.consts)) {
        if (artifact[field] !== expected) {
          pushError(
            errors,
            'const_mismatch',
            `artifact.${field}`,
            `must be ${expected}`,
            expected,
            artifact[field],
          );
        }
      }
      for (const [field, expected] of Object.entries(contract.types)) {
        if (artifact[field] !== undefined || contract.required.includes(field)) {
          validateSchemaType(errors, artifact[field], expected, `artifact.${field}`);
        }
      }
      for (const [field, allowed] of Object.entries(contract.enums ?? {})) {
        if (artifact[field] !== undefined && !allowed.includes(artifact[field])) {
          pushError(
            errors,
            'enum_mismatch',
            `artifact.${field}`,
            `must be one of: ${allowed.join(', ')}`,
            allowed.join(', '),
            artifact[field],
          );
        }
      }
    }
  }
  return {
    ok: errors.length === 0,
    artifactKind: isObject(artifact) ? artifact.artifactKind : undefined,
    schemaVersion: isObject(artifact) ? artifact.schemaVersion : undefined,
    errors,
  };
}

export function assertPlanArtifact(artifact) {
  const result = validatePlanArtifact(artifact);
  if (!result.ok) throw validationError('Invalid Doe plan artifact', result);
  return artifact;
}

export function classifyPlan(value) {
  if (Array.isArray(value)) return validateCommandStream(value);
  if (isObject(value) && Array.isArray(value.commands)) return validateNormalizedPlan(value);
  return validatePlanArtifact(value);
}
