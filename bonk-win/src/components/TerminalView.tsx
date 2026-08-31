import { useEffect, useRef, useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";
import { Button, Chip, Card } from "@heroui/react";
import { HostItem } from "../lib/types";
import { sshConnect, sshWrite, sshResize, sshDisconnect } from "../lib/tauri";
import { listen } from "@tauri-apps/api/event";

const isTauri = typeof window !== "undefined" && !!(window as unknown as { __TAURI__?: unknown }).__TAURI__;

export default function TerminalView({ host }: { host: HostItem }) {
  const containerRef = useRef<HTMLDivElement>(null);
  const termRef = useRef<Terminal | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const sessionRef = useRef<string | null>(null);
  const [status, setStatus] = useState<"connecting" | "connected" | "disconnected">("connecting");
  const [latency, setLatency] = useState<number | null>(null);

  useEffect(() => {
    if (!containerRef.current) return;

    const term = new Terminal({
      fontFamily: "'JetBrains Mono','Cascadia Code',ui-monospace,monospace",
      fontSize: 13,
      lineHeight: 1.25,
      letterSpacing: 0,
      cursorBlink: true,
      cursorStyle: "block",
      theme: {
        background: "#0e0e10",
        foreground: "#e6e6e6",
        cursor: "#e6e6e6",
        selectionBackground: "#264f78",
        black: "#1a1a1a",
        brightBlack: "#5a5a5a",
      },
      allowTransparency: false,
    });

    const fitAddon = new FitAddon();
    const linkAddon = new WebLinksAddon();
    term.loadAddon(fitAddon);
    term.loadAddon(linkAddon);
    term.open(containerRef.current);
    // Delay fit to ensure container has size
    requestAnimationFrame(() => {
      try { fitAddon.fit(); } catch {}
    });

    termRef.current = term;
    fitRef.current = fitAddon;

    // Mock path: Vite dev without Tauri backend
    if (!isTauri) {
      setStatus("connected");
      setLatency(12);
      term.writeln("\x1b[90m— Bonk Win Preview (mock, no Rust backend) —\x1b[0m");
      term.writeln(`\x1b[32m● Connected to ${host.name} \x1b[90m${host.username}@${host.host}:${host.port}\x1b[0m`);
      term.writeln("\x1b[90mType `help` for mock commands, `clear` to clear.\x1b[0m\r");
      term.write("$ ");
      const disp = term.onData((data) => {
        if (data === "\r") {
          const y = term.buffer.active.cursorY;
          const line = term.buffer.active.getLine(y)?.translateToString().trim() ?? "";
          const cmd = line.replace(/^\$\s*/, "").trim();
          if (cmd === "clear") {
            term.clear();
          } else if (cmd === "help") {
            term.writeln("\r\n\x1b[36mAvailable (mock):\x1b[0m help, clear, ls, pwd, whoami, sftp");
          } else if (cmd.startsWith("ls")) {
            term.writeln("\r\n\x1b[34mCargo.toml\x1b[0m  \x1b[34msrc\x1b[0m  \x1b[90mREADME.md\x1b[0m  \x1b[32mbonk-core\x1b[0m");
          } else if (cmd === "pwd") {
            term.writeln("\r\n/home/" + host.username);
          } else if (cmd === "whoami") {
            term.writeln("\r\n" + host.username);
          } else if (cmd) {
            term.writeln(`\r\n\x1b[90m[mock] executed: ${cmd}\x1b[0m`);
          }
          term.write("\r\n$ ");
        } else if (data === "\x7f") {
          // backspace
          term.write("\b \b");
        } else {
          term.write(data);
        }
      });
      const onResize = () => { try { fitAddon.fit(); } catch {} };
      window.addEventListener("resize", onResize);
      const ro = new ResizeObserver(onResize);
      ro.observe(containerRef.current!);
      return () => {
        disp.dispose();
        window.removeEventListener("resize", onResize);
        ro.disconnect();
        term.dispose();
      };
    }

    // Real Tauri path
    let unlisten: (() => void) | null = null;
    let cancelled = false;

    (async () => {
      try {
        term.writeln(`\x1b[90mConnecting to ${host.username}@${host.host}:${host.port}...\x1b[0m`);
        const sessionId = await sshConnect({
          host: host.host, port: host.port, username: host.username,
          authType: host.authType, secret: undefined,
        });
        if (cancelled) { sshDisconnect(sessionId); return; }
        sessionRef.current = sessionId;
        setStatus("connected");
        term.writeln(`\x1b[32m● Session ${sessionId.slice(0, 8)} ready\x1b[0m`);

        unlisten = await listen<string>(`pty-data://${sessionId}`, (e) => {
          term.write(e.payload);
        });

        term.onData((data) => {
          if (sessionRef.current) sshWrite(sessionRef.current, data);
        });

        const dims = fitAddon.proposeDimensions();
        if (dims && sessionRef.current) sshResize(sessionRef.current, dims.cols, dims.rows);

        const ro = new ResizeObserver(() => {
          try { fitAddon.fit(); } catch {}
          const d = fitAddon.proposeDimensions();
          if (d && sessionRef.current) sshResize(sessionRef.current, d.cols, d.rows);
        });
        ro.observe(containerRef.current!);
      } catch (e) {
        setStatus("disconnected");
        term.writeln(`\x1b[31m✗ ${String(e)}\x1b[0m`);
      }
    })();

    return () => {
      cancelled = true;
      if (unlisten) unlisten();
      if (sessionRef.current) sshDisconnect(sessionRef.current);
      term.dispose();
    };
  }, [host.id, host.name, host.host, host.port, host.username, host.authType]);

  return (
    <div className="flex-1 flex flex-col min-h-0 bg-[#0e0e10] relative">
      {/* Status bar like Mac ServerResourceStats */}
      <motion.div
        initial={{ opacity: 0, y: -4 }}
        animate={{ opacity: 1, y: 0 }}
        className="h-7 flex items-center gap-2 px-3 bg-[oklch(0.12_0_0)] border-b border-[oklch(0.18_0_0)] text-[11px] shrink-0"
      >
        <span className={`w-2 h-2 rounded-full ${status === "connected" ? "bg-[oklch(0.68_0.15_142)]" : status === "connecting" ? "bg-[oklch(0.75_0.15_65)] animate-pulse" : "bg-[oklch(0.62_0.22_25)]"}`} />
        <span className="font-medium text-[oklch(0.85_0_0)]">{host.name}</span>
        <span className="text-[oklch(0.5_0_0)] font-mono">{host.username}@{host.host}:{host.port}</span>
        <span className="text-[oklch(0.35_0_0)]">•</span>
        <span className={`capitalize ${status === "connected" ? "text-[oklch(0.68_0.15_142)]" : "text-[oklch(0.55_0_0)]"}`}>{status}</span>
        {latency !== null && <Chip size="sm" variant="soft" color="success" className="h-4 text-[10px] ml-1">{latency} ms</Chip>}
        <div className="flex-1" />
        <div className="hidden sm:flex items-center gap-1.5">
          <Button size="sm" variant="ghost" className="h-6 text-[11px] px-2 min-w-0">Broadcast</Button>
          <Button size="sm" variant="ghost" className="h-6 text-[11px] px-2 min-w-0">SFTP</Button>
          <Button size="sm" variant="ghost" className="h-6 text-[11px] px-2 min-w-0">Clear</Button>
        </div>
      </motion.div>

      <div ref={containerRef} className="flex-1 min-h-0 p-1" />

      {/* Floating hint for mock mode */}
      {!isTauri && (
        <motion.div initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.6 }} className="absolute bottom-3 right-3">
          <Card className="px-3 py-2 bg-[oklch(0.18_0_0)] border-[oklch(0.25_0_0)] shadow-lg">
            <div className="text-[11px] text-[oklch(0.65_0_0)]">Mock terminal — run <span className="text-[oklch(0.85_0_0)] font-mono">npm run tauri:dev</span> for real SSH</div>
          </Card>
        </motion.div>
      )}
    </div>
  );
}
