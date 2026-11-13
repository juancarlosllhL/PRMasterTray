// A request/response client over a worker-like object (anything with
// `postMessage` and `on("message" | "error" | "exit")`). Kept apart from
// Electron and from the worker itself so it can be tested with a real one.

export function createWorkerClient(worker) {
  let nextId = 1;
  const pending = new Map();

  const failAll = (error) => {
    for (const { reject } of pending.values()) reject(error);
    pending.clear();
  };

  worker.on("message", ({ id, ...answer }) => {
    const request = pending.get(id);
    if (!request) return;
    pending.delete(id);
    if (answer.error) request.reject(new Error(answer.error));
    else request.resolve(answer);
  });
  worker.on("error", failAll);
  worker.on("exit", (code) => failAll(new Error(`worker exited with code ${code}`)));

  return {
    request(payload) {
      return new Promise((resolve, reject) => {
        const id = nextId++;
        pending.set(id, { resolve, reject });
        worker.postMessage({ id, ...payload });
      });
    },
    get pending() {
      return pending.size;
    },
  };
}
