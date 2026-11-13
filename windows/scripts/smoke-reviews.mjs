// Live check of the review-requests path: token -> teams -> per-team searches.
import { fetchReviewRequests, fetchTeams, reviewRows } from "../src/core/reviews.js";
import { readToken } from "../src/core/token.js";

const token = await readToken();
const teams = await fetchTeams({ token });
console.log(`${teams.length} teams:`, teams.map((t) => t.combinedSlug).join(", "));
const { requests, pendingCounts } = await fetchReviewRequests({ token, teams });
console.log("pending per team:", JSON.stringify(pendingCounts));
for (const r of reviewRows(requests).slice(0, 5)) console.log(` ${r.repo} #${r.number} [${r.status}] ${r.author} · ${r.teams} · ${r.size} · ${r.age}`);
console.log(`${requests.length} requests in total`);
