import { motion } from "framer-motion";
import type { HostItem } from "../lib/types";

export default function Inspector({ host, onClose }: { host: HostItem; onClose: () => void }) {
  return (
    <motion.div
      initial={{ opacity: 0, x: 14 }}
      animate={{ opacity: 1, x: 0 }}
      exit={{ opacity: 0, x: 14 }}
      transition={{ type: "spring", stiffness: 400, damping: 30 }}
      className="w-[300px] bg-[#141414] border-l border-[#2a2a2a] flex flex-col shrink-0"
    >
      <div className="h-8 flex items-center justify-between px-3 border-b border-[#2a2a2a] shrink-0">
        <span className="text-xs font-semibold tracking-wide text-white">Inspector</span>
        <button onClick={onClose} className="w-6 h-6 rounded-md flex items-center justify-center hover:bg-[#222] text-[#6a6a6a] text-xs">
          ×
        </button>
      </div>
      <div className="flex-1 overflow-y-auto thin-scrollbar p-3 flex flex-col gap-3">
        <div className="p-3 rounded-lg bg-[#1a1a1a] border border-[#2a2a2a]">
          <div className="text-xs font-semibold text-white mb-2">Host</div>
          <div className="space-y-1.5 text-xs">
            <Row label="Name" value={host.name} />
            <Row label="Address" value={`${host.host}:${host.port}`} mono />
            <Row label="User" value={host.username} mono />
            <Row label="Auth" value={host.authType} />
          </div>
        </div>
        <div className="p-3 rounded-lg bg-[#1a1a1a] border border-[#2a2a2a]">
          <div className="text-xs font-semibold text-white mb-2">Connection</div>
          <div className="flex gap-1.5 flex-wrap">
            <span className="text-[10px] px-2 py-1 rounded-full bg-[#222] border border-[#2a2a2a] text-[#8a8a8a]">SSH-2.0</span>
            <span className="text-[10px] px-2 py-1 rounded-full bg-[#1e1e1e] border border-[#2a2a2a] text-[#8a8a8a]">xterm-256color</span>
            <span className="text-[10px] px-2 py-1 rounded-full bg-[#0a3d1a] border border-[#1a5a2a] text-[#30d158]">Encrypted</span>
          </div>
          <div className="h-px bg-[#222] my-3" />
          <div className="flex gap-1.5">
            <button className="flex-1 h-7 rounded-md bg-[#222] hover:bg-[#2a2a2a] border border-[#2a2a2a] text-xs text-white">Reconnect</button>
            <button className="flex-1 h-7 rounded-md hover:bg-[#1a1a1a] border border-[#2a2a2a] text-xs text-[#8a8a8a]">Duplicate</button>
          </div>
        </div>
        <div className="p-3 rounded-lg bg-[#1a1a1a] border border-[#2a2a2a]">
          <div className="text-xs font-semibold text-white mb-1.5">Snippets</div>
          <div className="text-xs text-[#5a5a5a] leading-relaxed">No snippets yet. Save frequent commands here.</div>
          <button className="w-full mt-2 h-7 rounded-md hover:bg-[#222] border border-[#2a2a2a] text-xs text-[#8a8a8a]">＋ Add Snippet</button>
        </div>
        <div className="p-3 rounded-lg bg-[#1a1a1a] border border-[#2a2a2a]">
          <div className="text-xs font-semibold text-white mb-1.5">AI Assistant</div>
          <div className="text-xs text-[#5a5a5a] leading-relaxed">Ask to explain this host’s logs or generate a command.</div>
          <button className="w-full mt-2 h-7 rounded-full bg-[#0a84ff] hover:bg-[#0066cc] text-xs font-medium text-white">✦ Ask AI</button>
        </div>
      </div>
    </motion.div>
  );
}
function Row({ label, value, mono }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="flex items-center justify-between gap-2 text-xs">
      <span className="text-[#5a5a5a]">{label}</span>
      <span className={`truncate text-white ${mono ? "font-mono text-[11px]" : ""}`}>{value}</span>
    </div>
  );
}
