import { spawnSync } from "node:child_process";

export function runSync(command, args, { cwd, input, timeoutMs } = {}) {
  return spawnSync(command, args, {
    cwd: cwd ?? process.cwd(),
    input,
    encoding: "utf8",
    timeout: timeoutMs,
    maxBuffer: 32 * 1024 * 1024
  });
}
