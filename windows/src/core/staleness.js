const DAY_MS = 86_400_000;

// Measured from when the PR was opened, not its last activity: updating behind
// branches bumps updatedAt, which would reset the signal forever.
// Strictly greater than, so the marker never appears a day early. null = off.
export function isStale(createdAt, now, thresholdDays) {
  if (thresholdDays == null) return false;
  return now - new Date(createdAt) > thresholdDays * DAY_MS;
}

const unit = (count, noun) => (count === 1 ? `1 ${noun}` : `${count} ${noun}s`);

export function ageLabel(createdAt, now) {
  // Clamped: a clock ahead of GitHub's would otherwise give a negative age.
  const days = Math.max(0, Math.floor((now - new Date(createdAt)) / DAY_MS));
  if (days < 60) return unit(days, "day");
  if (days < 365) return unit(Math.floor(days / 30), "month");
  return unit(Math.floor(days / 365), "year");
}
