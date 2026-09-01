const providerTarget = process.env.DOE_CTS_DAWN_PROVIDER_TARGET;

if (!providerTarget) {
  throw new Error('DOE_CTS_DAWN_PROVIDER_TARGET is required');
}

const provider = require(providerTarget);

if (typeof provider.create !== 'function' || !provider.globals) {
  throw new Error(`invalid Dawn CTS provider target: ${providerTarget}`);
}

Object.assign(globalThis, provider.globals);

module.exports = {
  create: provider.create,
};
