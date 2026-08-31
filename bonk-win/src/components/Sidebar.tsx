import { useState } from "react";
import {
  Zap, Layers, FlaskConical, Beaker, Package, Database, HardDrive, Server,
  Search, ChevronDown, Hash, Plus, X
} from "lucide-react";
import { useAppStore } from "../lib/store";
import type { HostItem } from "../lib/types";

// 群组图标映射 — Lucide，统一描边 1.8
const GROUP_ICONS: Record<string, typeof Zap> = {
  "电力": Zap,
  "大融合": Layers,
  "奉贤测试": FlaskConical,
  "杭州测试": Beaker,
  "打包机器": Package,
  "达梦数据库": Database,
  "宿主机": HardDrive,
};

export default function Sidebar() {
  const { hosts, groups, tabs, searchQuery, setSearchQuery, openTab } = useAppStore();
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>({});
  const filtered = hosts.filter(
    (h) => !searchQuery || h.name.toLowerCase().includes(searchQuery.toLowerCase()) || h.host.toLowerCase().includes(searchQuery.toLowerCase())
  );
  const grouped = (() => {
    const map = new Map<string, HostItem[]>();
    for (const h of filtered) {
      const g = groups.find((x) => x.id === h.groupId) ?? { name: "未分组", color: "#8a8886" } as any;
      const name = g.name;
      if (!map.has(name)) map.set(name, []);
      map.get(name)!.push(h);
    }
    const order = ["电力", "大融合", "奉贤测试", "杭州测试", "打包机器", "达梦数据库", "宿主机"];
    return Array.from(map.entries()).sort((a, b) => order.indexOf(a[0]) - order.indexOf(b[0]));
  })();
  const tabsByHostId = new Map(tabs.map((t) => [t.host.id, t]));

  return (
    <div className="w-[260px] bg-[#fafafa] border-r border-[#e5e5e5] flex flex-col shrink-0 select-none">
      {/* Windows 侧栏标题 - Fluent 12px Semibold */}
      <div className="h-8 flex items-center justify-between px-3 shrink-0">
        <span className="text-[12px] font-semibold text-[#1a1a1a] tracking-tight">主机</span>
        <span className="text-[11px] px-2 py-0.5 rounded-full bg-white border border-[#e5e5e5] text-[#605e5c] font-medium">{hosts.length}</span>
      </div>

      <div className="flex-1 overflow-y-auto thin-scrollbar px-2 py-1">
        <div className="flex flex-col gap-2">
          {grouped.map(([groupName, items]) => {
            const g = groups.find((x) => x.name === groupName);
            const isCollapsed = collapsed[groupName] ?? false;
            const Icon = GROUP_ICONS[groupName] ?? Hash;
            return (
              <div key={groupName}>
                <button
                  onClick={() => setCollapsed(s=> ({...s, [groupName]: !isCollapsed}))}
                  className="w-full flex items-center gap-1.5 px-1 py-1 rounded-[4px] hover:bg-[#f0f0f0] text-left transition-colors duration-150 cursor-pointer"
                  aria-expanded={!isCollapsed}
                >
                  <ChevronDown size={12} className={`text-[#605e5c] transition-transform duration-200 ${isCollapsed ? "-rotate-90" : ""}`} strokeWidth={2} />
                  <span className="w-2 h-2 rounded-full shrink-0" style={{ background: g?.color ?? "#8a8886" }} />
                  <Icon size={13} className="shrink-0" style={{ color: g?.color ?? "#8a8886" }} strokeWidth={1.8} />
                  <span className="text-[12px] font-semibold text-[#1a1a1a] flex-1 truncate">{groupName}</span>
                  <span className="text-[11px] text-[#8a8886] font-medium">{items.length}</span>
                </button>
                {!isCollapsed && (
                  <div className="flex flex-col gap-0.5 mt-0.5 animate-in fade-in duration-150">
                    {items.map((host) => {
                      const isActive = tabsByHostId.has(host.id);
                      return (
                        <button
                          key={host.id}
                          onClick={() => openTab(host)}
                          className={`w-full flex items-center gap-2 pl-6 pr-2 py-1.5 rounded-[4px] text-left border text-[12px] transition-all duration-150 cursor-pointer ${
                            isActive
                              ? "bg-[#deecf9] border-[#c7d8f0] text-[#0078d4]"
                              : "bg-transparent border-transparent text-[#1a1a1a] hover:bg-[#f0f0f0] hover:border-[#e5e5e5]"
                          }`}
                          title={host.host}
                        >
                          <Server size={12} className={`shrink-0 ${isActive ? "text-[#0078d4]" : "text-[#8a8886]"}`} strokeWidth={1.8} />
                          <span className="flex-1 min-w-0 truncate font-medium">{host.name}</span>
                          <span className={`w-1.5 h-1.5 rounded-full shrink-0 ${isActive ? "bg-[#0078d4]" : "bg-transparent"}`} />
                        </button>
                      );
                    })}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </div>

      {/* Windows 搜索 — 8px 圆角白框，focus 蓝环 */}
      <div className="shrink-0 p-2 border-t border-[#e5e5e5] bg-[#f3f3f3]">
        <div className="flex items-center gap-2 h-8 px-2.5 rounded-[4px] bg-white border border-[#e5e5e5] focus-within:border-[#0078d4] focus-within:ring-1 focus-within:ring-[#0078d4] transition-all duration-150">
          <Search size={14} className="text-[#8a8886] shrink-0" strokeWidth={1.8} />
          <input
            placeholder="搜索主机"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            className="flex-1 bg-transparent outline-none text-[12px] placeholder:text-[#8a8886] text-[#1a1a1a]"
            aria-label="搜索主机"
          />
          {searchQuery && (
            <button onClick={()=>setSearchQuery("")} className="text-[#8a8886] hover:text-[#1a1a1a] p-0.5 rounded hover:bg-[#f0f0f0] transition-colors cursor-pointer" aria-label="清除">
              <X size={12} strokeWidth={2} />
            </button>
          )}
        </div>
        <div className="flex items-center justify-between mt-2 px-1">
          <span className="text-[11px] text-[#8a8886]">已选 {tabs.length} 会话</span>
          <button className="text-[11px] text-[#0078d4] hover:text-[#106ebe] hover:underline flex items-center gap-1 transition-colors cursor-pointer">
            <Plus size={12} strokeWidth={2} /> 新建主机
          </button>
        </div>
      </div>
    </div>
  );
}
