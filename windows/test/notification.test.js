import { test } from "node:test";
import assert from "node:assert/strict";
import { decide } from "../src/core/notification.js";

const pr = (id, readiness) => ({ id, readiness });

test("notifies only ready pull requests not yet notified", () => {
  const { notify, updated } = decide([pr("a", "ready"), pr("b", "ready"), pr("c", "blocked")], new Set(["a"]));
  assert.deepEqual(notify.map((p) => p.id), ["b"]);
  assert.deepEqual([...updated].sort(), ["a", "b"]);
});

test("a pull request that stops being ready is re-armed", () => {
  const first = decide([pr("a", "ready")], new Set());
  const dropped = decide([pr("a", "checksPending")], first.updated);
  assert.equal(dropped.updated.size, 0);
  assert.equal(decide([pr("a", "ready")], dropped.updated).notify.length, 1);
});

test("one that vanished from the list is forgotten", () => {
  assert.equal(decide([], new Set(["gone"])).updated.size, 0);
});
