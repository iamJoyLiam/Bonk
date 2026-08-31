import { useState } from "react";
import {
  Plus, Columns2, Radio, CircleDot, FolderTree, ArrowLeftRight, Code2,
  Settings, MoreHorizontal, Search, Command, Sparkles, LayoutGrid
} from "lucide-react";
import { useAppStore } from "../lib/store";

// Windows 11 Fluent CommandBar — Lucide icons, Micro-interactions 150-300ms
export default function Toolbar() {
  const { hosts, tabs } = useAppStore();
  const [showSettings, setShowSettings] = useState(false);

  return (
    <div className="h-12 flex items-center gap-2 px-3 bg-[#f3f3f3] border-b border-[#e5e5e5] shrink-0 select-none">
      {/* 左：主命令 */}
      <div className="flex items-center gap-1">
        <button className="h-8 px-3 rounded-[4px] bg-white border border-[#e5e5e5] hover:bg-[#f0f0f0] flex items-center gap-1.5 text-[13px] text-[#1a1a1a] shadow-sm transition-colors duration-150 cursor-pointer">
          <Plus size={14} strokeWidth={2} /> 新建连接
        </button>
        <div className="w-px h-5 bg-[#e5e5e5] mx-1" />
        <button className="h-8 w-8 rounded-[4px] hover:bg-[#e5e5e5] flex items-center justify-center text-[#605e5c] transition-colors duration-150 cursor-pointer" title="分屏" aria-label="分屏">
          <Columns2 size={16} strokeWidth={1.8} />
        </button>
        <button className="h-8 w-8 rounded-[4px] hover:bg-[#e5e5e5] flex items-center justify-center text-[#605e5c] transition-colors duration-150 cursor-pointer" title="广播到全部会话" aria-label="广播">
          <Radio size={16} strokeWidth={1.8} />
        </button>
        <button className="h-8 w-8 rounded-[4px] hover:bg-[#e5e5e5] flex items-center justify-center text-[#e81123] transition-colors duration-150 cursor-pointer" title="录制" aria-label="录制">
          <CircleDot size={16} strokeWidth={1.8} />
        </button>
      </div>

      <div className="flex-1" />

      {/* 中：状态 — Windows 卡片，非 Mac 药丸 */}
      <div className="hidden md:flex items-center gap-2">
        <span className="h-6 px-2.5 rounded-full bg-[#deecf9] border border-[#c7d8f0] text-[11px] text-[#0078d4] flex items-center gap-1.5 font-medium">
          <span className="w-2 h-2 rounded-full bg-[#0078d4] animate-pulse" /> 已连接 {tabs.length}
        </span>
        <span className="h-6 px-2.5 rounded-full bg-white border border-[#e5e5e5] text-[11px] text-[#605e5c] hidden lg:flex items-center gap-1">
          <LayoutGrid size={12} strokeWidth={1.8} /> 共 {hosts.length} 台
        </span>
      </div>

      <div className="w-px h-5 bg-[#e5e5e5] mx-2 hidden md:block" />

      {/* 右：工具 — Lucide 一致描边 1.8 */}
      <div className="flex items-center gap-1">
        <button className="h-8 w-8 rounded-[4px] hover:bg-white hover:border hover:border-[#e5e5e5] flex items-center justify-center text-[#605e5c] border border-transparent transition-all duration-150 cursor-pointer" title="SFTP 文件" aria-label="SFTP">
          <FolderTree size={16} strokeWidth={1.8} />
        </button>
        <button className="h-8 w-8 rounded-[4px] hover:bg-white hover:border hover:border-[#e5e5e5] flex items-center justify-center text-[#605e5c] border border-transparent transition-all duration-150 cursor-pointer" title="端口转发" aria-label="端口转发">
          <ArrowLeftRight size={16} strokeWidth={1.8} />
        </button>
        <button className="h-8 w-8 rounded-[4px] hover:bg-white hover:border hover:border-[#e5e5e5] flex items-center justify-center text-[#605e5c] border border-transparent transition-all duration-150 cursor-pointer" title="命令片段" aria-label="片段">
          <Code2 size={16} strokeWidth={1.8} />
        </button>
        <button className="h-8 w-8 rounded-[4px] hover:bg-white hover:border hover:border-[#e5e5e5] flex items-center justify-center text-[#605e5c] border border-transparent transition-all duration-150 cursor-pointer" title="命令面板" aria-label="命令面板">
          <Command size={16} strokeWidth={1.8} />
        </button>
        <div className="w-px h-5 bg-[#e5e5e5] mx-1" />
        <div className="relative">
          <button onClick={() => setShowSettings(v=>!v)} className="h-8 w-8 rounded-[4px] bg-white border border-[#e5e5e5] hover:bg-[#f0f0f0] flex items-center justify-center text-[#605e5c] shadow-sm transition-colors duration-150 cursor-pointer" title="设置" aria-label="设置" aria-expanded={showSettings}>
            <Settings size={16} strokeWidth={1.8} />
          </button>
          {showSettings && (
            <div className="absolute right-0 top-9 w-56 bg-white border border-[#e5e5e5] rounded-[8px] shadow-lg py-1 z-50 text-[13px] animate-in fade-in slide-in-from-top-1 duration-150">
              <div className="px-3 py-1.5 text-[11px] font-semibold text-[#8a8886] uppercase tracking-wider">设置</div>
              <button className="w-full text-left px-3 py-2 hover:bg-[#f3f3f3] flex items-center gap-2 transition-colors"><Settings size={14}/> 首选项</button>
              <button className="w-full text-left px-3 py-2 hover:bg-[#f3f3f3] flex items-center gap-2 transition-colors"><FolderTree size={14}/> 导入/导出</button>
              <button className="w-full text-left px-3 py-2 hover:bg-[#f3f3f3] flex items-center gap-2 transition-colors"><Command size={14}/> 快捷键</button>
              <div className="h-px bg-[#e5e5e5] my-1" />
              <button className="w-full text-left px-3 py-2 hover:bg-[#f3f3f3] flex items-center gap-2 transition-colors"><Sparkles size={14}/> 关于 Bonk</button>
            </div>
          )}
        </div>
        <button className="h-8 w-8 rounded-[4px] hover:bg-[#e5e5e5] flex items-center justify-center text-[#605e5c] transition-colors duration-150 cursor-pointer" title="更多" aria-label="更多">
          <MoreHorizontal size={16} strokeWidth={1.8} />
        </button>
      </div>
    </div>
  );
}
