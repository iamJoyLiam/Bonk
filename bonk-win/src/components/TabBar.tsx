import { Server, X, Plus } from "lucide-react";
import { useAppStore } from "../lib/store";

// Windows 11 选项卡 — Lucide + 150ms 过渡，44px 触达
export default function TabBar() {
  const { tabs, activeTabId, setActiveTab, closeTab } = useAppStore();
  if (tabs.length === 0) return null;
  return (
    <div className="h-9 flex items-end gap-1 px-2 bg-[#f3f3f3] border-b border-[#e5e5e5] shrink-0 overflow-x-auto">
      {tabs.map((tab) => {
        const isActive = tab.id === activeTabId;
        return (
          <div
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            className={`group flex items-center gap-2 h-7 px-3 rounded-t-[6px] border text-[12px] cursor-pointer shrink-0 min-w-[120px] max-w-[180px] transition-all duration-150 ${
              isActive
                ? "bg-white border-[#e5e5e5] border-b-white text-[#1a1a1a] shadow-sm -mb-px"
                : "bg-[#e5e5e5] border-transparent text-[#605e5c] hover:bg-[#eaeaea] hover:text-[#1a1a1a]"
            }`}
            role="tab"
            aria-selected={isActive}
          >
            <Server size={12} className={`shrink-0 ${isActive ? "text-[#0078d4]" : "text-[#8a8886]"}`} strokeWidth={1.8} />
            <span className="flex-1 truncate font-medium">{tab.title}</span>
            <button
              onClick={(e) => { e.stopPropagation(); closeTab(tab.id); }}
              className={`w-5 h-5 rounded-[4px] flex items-center justify-center shrink-0 transition-colors duration-150 ${isActive ? "hover:bg-[#f0f0f0] text-[#605e5c]" : "hover:bg-[#d1d1d1] text-[#605e5c]"}`}
              aria-label={`关闭 ${tab.title}`}
            >
              <X size={12} strokeWidth={2} />
            </button>
          </div>
        );
      })}
      <button className="w-7 h-7 mb-1 rounded-[4px] hover:bg-[#e5e5e5] flex items-center justify-center text-[#605e5c] shrink-0 transition-colors duration-150 cursor-pointer" aria-label="新建标签">
        <Plus size={14} strokeWidth={2} />
      </button>
    </div>
  );
}
