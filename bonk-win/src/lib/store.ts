import { create } from "zustand";
import type {
  HostItem, TerminalTab, PortForwardDto, ForwardHandle, SerialPortInfo, SnippetDto, CommandHistoryDto,
  WorkspaceDto, ServerInfoDto, RecordingMeta, BroadcastGroup, TeamMemberDto, TeamSessionDto, UserPreferencesDto
} from "./types";

// ---- Groups (1:1 复刻 Mac 截图) ----
const GROUPS = [
  { id: "g1", name: "电力", color: "#ff9500", icon: "⚡" },
  { id: "g2", name: "大融合", color: "#ff9500", icon: "⌂" },
  { id: "g3", name: "奉贤测试", color: "#ff2d92", icon: "⌖" },
  { id: "g4", name: "杭州测试", color: "#ff2d92", icon: "◈" },
  { id: "g5", name: "打包机器", color: "#5ac8fa", icon: "▭" },
  { id: "g6", name: "达梦数据库", color: "#af52de", icon: "◉" },
  { id: "g7", name: "宿主机", color: "#30dbc9", icon: "≡" },
] as const;

const HOSTS: HostItem[] = [
  { id: "h204", name: "192.168.100.204", host: "192.168.100.204", port: 22, username: "root", authType: "password", groupId: "g1" },
  { id: "h50", name: "192.168.100.50", host: "192.168.100.50", port: 22, username: "root", authType: "password", groupId: "g2" },
  { id: "h51", name: "192.168.100.51", host: "192.168.100.51", port: 22, username: "root", authType: "password", groupId: "g2" },
  { id: "h52", name: "192.168.100.52", host: "192.168.100.52", port: 22, username: "root", authType: "password", groupId: "g2" },
  { id: "h53", name: "192.168.100.53", host: "192.168.100.53", port: 22, username: "root", authType: "password", groupId: "g2" },
  { id: "h54", name: "192.168.100.54", host: "192.168.100.54", port: 22, username: "root", authType: "password", groupId: "g2" },
  { id: "h55", name: "192.168.100.55", host: "192.168.100.55", port: 22, username: "root", authType: "password", groupId: "g2" },
  { id: "h193", name: "192.168.100.193", host: "192.168.100.193", port: 22, username: "root", authType: "password", groupId: "g3" },
  { id: "h194", name: "192.168.100.194", host: "192.168.100.194", port: 22, username: "root", authType: "password", groupId: "g3" },
  { id: "h195", name: "192.168.100.195", host: "192.168.100.195", port: 22, username: "root", authType: "password", groupId: "g3" },
  { id: "h155", name: "192.168.100.155", host: "192.168.100.155", port: 22, username: "root", authType: "password", groupId: "g4" },
  { id: "h156", name: "192.168.100.156", host: "192.168.100.156", port: 22, username: "root", authType: "password", groupId: "g4" },
  { id: "h31", name: "192.168.100.31", host: "192.168.100.31", port: 22, username: "root", authType: "password", groupId: "g5" },
  { id: "h102", name: "172.16.10.102", host: "172.16.10.102", port: 22, username: "root", authType: "password", groupId: "g5" },
  { id: "h46", name: "192.168.100.46", host: "192.168.100.46", port: 22, username: "root", authType: "password", groupId: "g6" },
  { id: "h240", name: "192.168.100.240", host: "192.168.100.240", port: 22, username: "root", authType: "password", groupId: "g7" },
];

// ---- Store slices ----

interface HostSlice {
  hosts: HostItem[];
  setHosts: (h: HostItem[]) => void;
  upsertHost: (h: HostItem) => void;
  removeHost: (id: string) => void;
}

interface TabSlice {
  tabs: TerminalTab[];
  activeTabId: string | null;
  openTab: (host: HostItem) => void;
  closeTab: (id: string) => void;
  setActiveTab: (id: string) => void;
  bindSession: (tabId: string, sessionId: string) => void;
  splitTab: (tabId: string, direction: "horizontal" | "vertical") => void;
}

interface ForwardSlice { forwards: ForwardHandle[]; setForwards: (f: ForwardHandle[]) => void; }
interface SerialSlice { serialPorts: SerialPortInfo[]; setSerialPorts: (p: SerialPortInfo[]) => void; }
interface SnippetSlice { snippets: SnippetDto[]; history: CommandHistoryDto[]; setSnippets: (s: SnippetDto[]) => void; setHistory: (h: CommandHistoryDto[]) => void; }
interface WorkspaceSlice { workspaces: WorkspaceDto[]; setWorkspaces: (w: WorkspaceDto[]) => void; }
interface MonitorSlice { serverInfos: Record<string, ServerInfoDto>; setServerInfo: (hostId: string, info: ServerInfoDto) => void; }
interface RecordingSlice { recordings: RecordingMeta[]; setRecordings: (r: RecordingMeta[]) => void; }
interface BroadcastSlice { broadcasts: BroadcastGroup[]; activeBroadcastId: string | null; setBroadcasts: (b: BroadcastGroup[]) => void; setActiveBroadcast: (id: string | null) => void; }
interface TeamSlice { members: TeamMemberDto[]; teamSessions: TeamSessionDto[]; setMembers: (m: TeamMemberDto[]) => void; setTeamSessions: (s: TeamSessionDto[]) => void; }
interface SettingsSlice { preferences: UserPreferencesDto | null; setPreferences: (p: UserPreferencesDto) => void; }

interface AppState extends HostSlice, TabSlice, ForwardSlice, SerialSlice, SnippetSlice, WorkspaceSlice, MonitorSlice, RecordingSlice, BroadcastSlice, TeamSlice, SettingsSlice {
  groups: typeof GROUPS;
  sidebarCollapsed: boolean;
  searchQuery: string;
  setSearchQuery: (q: string) => void;
  toggleSidebar: () => void;
  initFromBackend: () => Promise<void>;
}

export const useAppStore = create<AppState>((set) => ({
  // Host
  hosts: HOSTS,
  groups: GROUPS as unknown as typeof GROUPS,
  setHosts: (hosts) => set({ hosts }),
  upsertHost: (h) => set((s) => {
    const idx = s.hosts.findIndex(x => x.id === h.id);
    if (idx >= 0) { const nh = [...s.hosts]; nh[idx] = h; return { hosts: nh }; }
    return { hosts: [...s.hosts, h] };
  }),
  removeHost: (id) => set((s) => ({ hosts: s.hosts.filter(x => x.id !== id) })),

  // Tabs / split
  tabs: [{ id: "t1", host: HOSTS.find(h => h.id === "h195")!, title: "192.168.100.195" }],
  activeTabId: "t1",
  openTab: (host) => set((s) => {
    const existing = s.tabs.find((t) => t.host.id === host.id);
    if (existing) return { activeTabId: existing.id };
    const tab: TerminalTab = { id: crypto.randomUUID(), host, title: host.name };
    return { tabs: [...s.tabs, tab], activeTabId: tab.id };
  }),
  closeTab: (id) => set((s) => {
    const idx = s.tabs.findIndex((t) => t.id === id);
    const nextTabs = s.tabs.filter((t) => t.id !== id);
    let nextActive = s.activeTabId;
    if (s.activeTabId === id) {
      if (nextTabs.length === 0) nextActive = null;
      else if (idx < nextTabs.length) nextActive = nextTabs[idx].id;
      else nextActive = nextTabs[nextTabs.length - 1].id;
    }
    return { tabs: nextTabs, activeTabId: nextActive };
  }),
  setActiveTab: (id) => set({ activeTabId: id }),
  bindSession: (tabId, sessionId) => set((s) => ({ tabs: s.tabs.map(t => t.id===tabId? { ...t, sessionId }: t) })),
  splitTab: (_tabId, _dir) => {
    // 占位：真实分屏由 LayoutNodeDto + Workspace 驱动，P0 先日志
    console.log("[mock split]", _tabId, _dir);
  },

  // Forwards
  forwards: [],
  setForwards: (forwards) => set({ forwards }),

  // Serial
  serialPorts: [],
  setSerialPorts: (serialPorts) => set({ serialPorts }),

  // Snippet / History
  snippets: [],
  history: [],
  setSnippets: (snippets) => set({ snippets }),
  setHistory: (history) => set({ history }),

  // Workspace
  workspaces: [],
  setWorkspaces: (workspaces) => set({ workspaces }),

  // Monitor
  serverInfos: {},
  setServerInfo: (hostId, info) => set((s) => ({ serverInfos: { ...s.serverInfos, [hostId]: info } })),

  // Recording
  recordings: [],
  setRecordings: (recordings) => set({ recordings }),

  // Broadcast
  broadcasts: [],
  activeBroadcastId: null,
  setBroadcasts: (broadcasts) => set({ broadcasts }),
  setActiveBroadcast: (activeBroadcastId) => set({ activeBroadcastId }),

  // Team
  members: [],
  teamSessions: [],
  setMembers: (members) => set({ members }),
  setTeamSessions: (teamSessions) => set({ teamSessions }),

  // Settings
  preferences: null,
  setPreferences: (preferences) => set({ preferences }),

  // UI + backend sync
  sidebarCollapsed: false,
  searchQuery: "",
  setSearchQuery: (q) => set({ searchQuery: q }),
  toggleSidebar: () => set((s) => ({ sidebarCollapsed: !s.sidebarCollapsed })),
  initFromBackend: async () => {
    const isTauri = typeof window !== "undefined" && (window as unknown as { __TAURI__?: unknown }).__TAURI__ !== undefined;
    if (!isTauri) return;
    try {
      const { hostList, workspaceList, snippetList, historyList, forwardList, serialList, recordingList, broadcastList, teamDiscover, settingsLoad } = await import("./tauri");
      const hosts = await hostList();
      if (hosts.length > 0) set({ hosts: hosts as unknown as HostItem[] });
      try { const wss = await workspaceList(); set({ workspaces: wss as unknown as WorkspaceDto[] }); } catch {}
      try { const snips = await snippetList(); set({ snippets: snips as unknown as SnippetDto[] }); } catch {}
      try { const hist = await historyList(undefined, 100); set({ history: hist as unknown as CommandHistoryDto[] }); } catch {}
      try { const fw = await forwardList(); set({ forwards: fw as unknown as ForwardHandle[] }); } catch {}
      try { const recs = await recordingList(); set({ recordings: recs as unknown as RecordingMeta[] }); } catch {}
      try { const bcs = await broadcastList(); set({ broadcasts: bcs as unknown as BroadcastGroup[] }); } catch {}
      try { const mems = await teamDiscover(); set({ members: mems as unknown as TeamMemberDto[] }); } catch {}
      try { const prefs = await settingsLoad(); set({ preferences: prefs as unknown as UserPreferencesDto }); } catch {}
      try { const ports = await serialList(); set({ serialPorts: ports as unknown as SerialPortInfo[] }); } catch {}
    } catch (e) { console.warn("[store initFromBackend]", e); }
  },
}));

// ---- Selectors / helpers ----
export const selectActiveTab = (s: AppState) => s.tabs.find(t => t.id===s.activeTabId) ?? null;
export const selectFilteredHosts = (s: AppState) => {
  const q = s.searchQuery.toLowerCase();
  if (!q) return s.hosts;
  return s.hosts.filter(h => h.name.toLowerCase().includes(q) || h.host.toLowerCase().includes(q));
};
