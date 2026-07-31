import fs from "node:fs";

// `process.stdout.write` is asynchronous when stdout is a pipe (which it always
// is under Claude Code's Bash tool), and `process.exit` does not flush pending
// async writes: anything past the 64KB pipe buffer is silently dropped. Every
// SKILL parses this JSON, and the largest payloads (`peer_failed`, which
// embeds full Codex stdout) are exactly the ones that got truncated. Write
// synchronously to the fd instead, looping over partial writes.
export function writeAllSync(fd, text) {
  const buf = Buffer.from(text, "utf8");
  let offset = 0;
  while (offset < buf.length) {
    try {
      offset += fs.writeSync(fd, buf, offset, buf.length - offset);
    } catch (err) {
      // Non-blocking pipe with a full buffer: back off briefly and retry rather
      // than spinning. EPIPE means the reader is gone, so there is nothing left to do.
      if (err.code === "EAGAIN") {
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
        continue;
      }
      if (err.code === "EPIPE") return;
      throw err;
    }
  }
}
