import { useEffect } from "react";
import TitleBar from "./components/TitleBar";
import Toolbar from "./components/Toolbar";
import Sidebar from "./components/Sidebar";
import TabBar from "./components/TabBar";
import TerminalView from "./components/TerminalView";
import { useAppStore } from "./lib/store";

export default function App() {
  const { tabs, activeTabId, initFromBackend } = useAppStore();
  const activeTab = tabs.find((t) => t.id === activeTabId) ?? null;
  useEffect(() => { initFromBackend(); }, [initFromBackend]);

  return (
    <div className="h-screen w-screen flex flex-col overflow-hidden bg-[#f3f3f3] text-[#1a1a1a]">
      <TitleBar />
      <Toolbar />
      <div className="flex-1 flex min-h-0 overflow-hidden">
        <Sidebar />
        <div className="flex-1 flex flex-col min-w-0 bg-white overflow-hidden border-l border-[#e5e5e5]">
          <TabBar />
          <div className="flex-1 flex min-h-0 overflow-hidden">
            <div className="flex-1 flex flex-col min-w-0 overflow-hidden bg-[#1e1e1e]">
              {activeTab ? (
                <TerminalView key={activeTab.id} host={activeTab.host} />
              ) : (
                <div className="flex-1 flex flex-col items-center justify-center bg-[#f3f3f3] text-[#605e5c]">
                  <div className="w-12 h-12 rounded-[8px] bg-white border border-[#e5e5e5] flex items-center justify-center mb-3 text-[#0078d4]">≡</div>
                  <div className="text-[13px] font-semibold text-[#1a1a1a]">选择主机开始连接</div>
                  <div className="text-[12px] text-[#8a8886] mt-1">从左侧选择或新建连接</div>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function DisconnectedView({ host }: { host: string }) {
  return (
    <div className="flex-1 flex flex-col items-center justify-center bg-white">
      <div className="w-12 h-12 rounded-xl flex items-center justify-center mb-3" style={{ color: "#ff8080" }}>
        <svg width={48} height={48} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.2}>
          <path d="M13 2L4 14h7l-1 8 9-12h-7l1-8z" />
          <line x1={4} y1={4} x2={20} y2={20} strokeWidth={1.6} />
        </svg>
      </div>
      <div className="text-sm font-medium text-[#1d1d1f] mb-4">已断开</div>
      <button className="h-7 px-4 rounded-full bg-[#0a84ff] hover:bg-[#0066cc] text-white text-xs font-medium flex items-center gap-1.5">
        <span className="text-xs">↻</span> 重新连接
      </button>
    </div>
  );
}
