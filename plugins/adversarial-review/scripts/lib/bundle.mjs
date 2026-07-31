// Parsing for the fenced context files the SKILLs write between iterations.
//
// Section markers must match a WHOLE line, and we bind to the LAST end marker
// rather than the first. A non-greedy match against the first `===== X END =====`
// silently truncated any section whose body quoted the marker format, a real
// case when reviewing plans about this plugin. The section's true terminator is
// always the last such line, since an embedded example necessarily precedes it.
export function parseBundle(text, labels) {
  const out = {};
  const lines = String(text ?? "").split(/\r?\n/);
  for (const label of labels) {
    const startRe = new RegExp(`^={5}\\s*${label}\\s+START\\s*={5}$`);
    const endRe = new RegExp(`^={5}\\s*${label}\\s+END\\s*={5}$`);
    const start = lines.findIndex((l) => startRe.test(l.trim()));
    const end = start === -1 ? -1 : lines.findLastIndex((l) => endRe.test(l.trim()));
    out[label] = start !== -1 && end > start ? lines.slice(start + 1, end).join("\n").trim() : "";
  }
  return out;
}
