import { Terminal } from "lucide-react";

const isTauri = typeof window !== "undefined" && !!(window as unknown as { __TAURI__?: unknown }).__TAURI__;

// 标题栏：Tauri 原生（decorations:true）时隐藏，Web 预览用 Lucide + Fluent
export default function TitleBar() {
  if (isTauri) return null;
  return (
    <div className="h-8 flex items-center gap-3 px-3 select-none bg-[#f3f3f3] border-b border-[#e5e5e5] shrink-0">
      <div className="flex items-center gap-2">
        <div className="w-5 h-5 rounded-[4px] bg-[#0078d4] flex items-center justify-center text-white">
          <Terminal size={12} strokeWidth={2.2} />
        </div>
        <span className="text-[13px] font-semibold text-[#1a1a1a] tracking-tight">Bonk</span>
        <span className="hidden sm:inline text-[11px] text-[#605e5c] px-2 py-0.5 rounded-full bg-white border border-[#e5e5e5] font-medium">Windows 预览</span>
      </div>
      <div className="flex-1" />
      <div className="flex items-center h-8 -mr-3 text-[#605e5c]">
        <span className="w-11 h-8 flex items-center justify-center hover:bg-[#e5e5e5] text-[14px] transition-colors">—</span>
        <span className="w-11 h-8 flex items-center justify-center hover:bg-[#e5e5e5] transition-colors"><span className="w-[10px] h-[10px] border border-current rounded-[1px]" /></span>
        <span className="w-11 h-8 flex items-center justify-center hover:bg-[#e81123] hover:text-white transition-colors">×</span>
      </div>
    </div>
  );
}
