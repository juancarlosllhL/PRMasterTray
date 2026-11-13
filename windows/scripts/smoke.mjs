// Live check of the whole data path: gh token -> GitHub GraphQL -> readiness.
import { fetchMyPullRequests } from "../src/core/github.js";
import { readToken } from "../src/core/token.js";

const prs = await fetchMyPullRequests({ token: await readToken() });
console.log(`${prs.length} open PRs:`, prs.map((p) => p.readiness).join(", "));

import { newDeploymentsState } from "../src/core/deployments.js";
import { fetchShipments } from "../src/core/github.js";

const shipments = await fetchShipments({ token: await readToken(), windowDays: 7, deployments: newDeploymentsState() });
console.log(`${shipments.length} recently merged:`);
for (const { pr, status, environments } of shipments) console.log(` #${pr.number} ${pr.repo} -> ${status.kind}${status.version ? " " + status.version : ""}${status.name ? " " + status.name : ""} | ${environments.map((e) => `${e.environment}:${e.status.kind}${e.status.version ? " " + e.status.version : ""}`).join(", ")}`);
