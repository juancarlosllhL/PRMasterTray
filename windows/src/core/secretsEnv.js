// Secrets that may also come from the environment, so a key can be provided
// without typing it into Settings. What is saved in Settings always wins.
const FROM_ENV = { "openrouter-key": "OPENROUTER_API_KEY" };

export function withEnvFallback(secrets, env = process.env) {
  const fromEnv = (name) => {
    const value = env[FROM_ENV[name]]?.trim();
    return value ? value : null;
  };
  return {
    ...secrets,
    has: (name) => secrets.has(name) || fromEnv(name) !== null,
    get: (name) => secrets.get(name) ?? fromEnv(name),
  };
}
