import { invoke } from "@tauri-apps/api/core";
import { LogicalSize } from "@tauri-apps/api/dpi";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { confirm as confirmDialog, open as openDialog } from "@tauri-apps/plugin-dialog";
import {
  AppWindow,
  CircleFadingPlus,
  Dock,
  Folder,
  Languages,
  LayoutGrid,
  PanelLeft,
  PowerOff,
  Rocket,
  Settings2,
  X,
} from "lucide-react";
import {
  type ComponentType,
  type CSSProperties,
  type PointerEvent as ReactPointerEvent,
  type WheelEvent as ReactWheelEvent,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import floatingBallAvatarUrl from "./assets/inchspace-floating-avatar.svg";
import "./App.css";

const appLanguages = ["zh", "en"] as const;
const floatingBallStyles = ["rotatingGlobe", "networkSpeed", "systemPressure"] as const;
const mainWindowLabel = "main";
const floatingBallWindowLabel = "floating-ball";
const floatingBallDragThreshold = 6;

type AppLanguage = (typeof appLanguages)[number];
type FloatingBallStyle = (typeof floatingBallStyles)[number];
type LanguagePreference = "system" | AppLanguage;
type MenuId = "dock" | "settings";
type DockContentTabId = "programs" | "directories";
type TauriInternals = {
  metadata?: {
    currentWindow?: {
      label?: string;
    };
  };
};
type ClientPlatform = "linux" | "macos" | "other" | "windows";
type NavigatorWithUserAgentData = Navigator & {
  userAgentData?: {
    platform?: string;
  };
};

type SystemMetrics = {
  cpuUsage: number;
  downloadBytesPerSecond: number;
  memoryTotalBytes: number;
  memoryUsage: number;
  memoryUsedBytes: number;
  uploadBytesPerSecond: number;
};

type MenuItem = {
  id: MenuId;
  icon: ComponentType<{ size?: number; strokeWidth?: number }>;
  label: Record<AppLanguage, string>;
};

type DockGridSettings = {
  columns: number;
  rows: number;
};

type LaunchItem = {
  id: string;
  name: string;
  path: string;
  iconDataUrl?: string;
  group: string;
  position?: LaunchPosition;
  sortOrder?: number;
  createdAt: number;
};

type DirectoryItem = {
  id: string;
  name: string;
  path: string;
  comparisonPath?: string;
  iconDataUrl?: string;
  position?: LaunchPosition;
  sortOrder?: number;
  createdAt: number;
};

type LaunchPosition = {
  x: number;
  y: number;
};

type ApplicationInfo = {
  name: string;
  path: string;
  iconDataUrl?: string | null;
};

type DirectoryInfo = {
  name: string;
  path: string;
  comparisonPath: string;
  containingAppDirectoryPath?: string | null;
  iconDataUrl?: string | null;
};

type ApplicationFileFilter = {
  name: string;
  extensions: string[];
};

type ApplicationPickerOptions = {
  defaultPath?: string | null;
  filters: ApplicationFileFilter[];
};

type LaunchGroupLayout = {
  width: number;
  height: number;
  columns: number;
  iconSize: number;
  manualPosition?: boolean;
  manualSize?: boolean;
  position?: LaunchPosition;
  rows?: number;
};

type LaunchGroupDescriptor = {
  itemCount: number;
  name: string;
};

type LaunchGroupView = {
  displayName: string;
  items: LaunchItem[];
  name: string;
};

type LaunchRootEntry =
  | {
      id: string;
      item: LaunchItem;
      kind: "item";
    }
  | {
      group: LaunchGroupView;
      id: string;
      kind: "group";
    };

type LaunchRootInsertionTarget =
  | {
      index: number;
      kind: "index";
    }
  | {
      entryId: string;
      insertAfter: boolean;
      kind: "entry";
    };

type ResolvedRootEntryPositions = {
  groups: Map<string, LaunchPosition>;
  items: Map<string, LaunchPosition>;
};

type LaunchGroupPlacementCandidate = {
  descriptor: LaunchGroupDescriptor;
  index: number;
  layout: LaunchGroupLayout;
};

type LaunchGroupFlowCursor = {
  rowHeight: number;
  x: number;
  y: number;
};

type LaunchDragState = {
  dropX: number;
  dropY: number;
  insertAfterTarget: boolean;
  itemId: string;
  rootDropAction: LaunchRootDropAction | null;
  rootInsertIndex: number | null;
  showDropShadow: boolean;
  targetAction: "insert" | "merge";
  targetGroup: string | null;
  targetId: string | null;
  x: number;
  y: number;
};

type LaunchDragSession = {
  hasMoved: boolean;
  hasLongPressed: boolean;
  itemId: string;
  lastDropIntent?: LaunchDropIntent | null;
  previewStartX: number;
  previewStartY: number;
  sourceGroup: string;
  startX: number;
  startY: number;
};

type LaunchGroupDragState = {
  dropX: number;
  dropY: number;
  groupName: string;
  showDropShadow: boolean;
  x: number;
  y: number;
};

type LaunchGroupDragSession = {
  groupName: string;
  hasMoved: boolean;
  hasLongPressed: boolean;
  previewStartX: number;
  previewStartY: number;
  startX: number;
  startY: number;
};

type DirectoryDragState = {
  dropX: number;
  dropY: number;
  itemId: string;
  showDropShadow: boolean;
  x: number;
  y: number;
};

type DirectoryDragSession = {
  hasMoved: boolean;
  hasLongPressed: boolean;
  itemId: string;
  previewStartX: number;
  previewStartY: number;
  startX: number;
  startY: number;
};

type LaunchRootDropAction = "insert" | "position";

type LaunchDropIntent = {
  insertAfterTarget: boolean;
  rootDropAction?: LaunchRootDropAction;
  targetAction: "insert" | "merge";
  targetGroup: string | null;
  targetId: string | null;
};

type LaunchGroupSwipeSession = {
  groupName: string;
  hasClaimed: boolean;
  itemCount: number;
  layout: LaunchGroupLayout;
  offsetX: number;
  pageCount: number;
  sourceItemId?: string;
  startPage: number;
  startX: number;
  startY: number;
};

type LaunchGroupSwipeState = {
  groupName: string;
  isDragging: boolean;
  offsetX: number;
};

type LaunchGroupWheelState = {
  deltaX: number;
  lastTurnAt: number;
};

type LaunchRect = {
  bottom: number;
  height: number;
  left: number;
  right: number;
  top: number;
  width: number;
};

type InitialLaunchState = {
  dockGridSettings: DockGridSettings;
  directoryItems: DirectoryItem[];
  launchItems: LaunchItem[];
};

const menuItems: MenuItem[] = [
  {
    id: "dock",
    icon: Rocket,
    label: {
      zh: "启动台",
      en: "Launchpad",
    },
  },
  {
    id: "settings",
    icon: Settings2,
    label: {
      zh: "设置",
      en: "Settings",
    },
  },
];

const launchGroupLayoutsStorageKey = "inchspace.launchGroupLayouts";
const launchGroupNamesStorageKey = "inchspace.launchGroupNames";
const launchItemsStorageKey = "inchspace.launchItems";
const directoryItemsStorageKey = "inchspace.directoryItems";
const dockGridSettingsStorageKey = "inchspace.dockGridSettings";
const dockIconVisibleStorageKey = "inchspace.dockIconVisible";
const floatingBallStyleStorageKey = "inchspace.floatingBallStyle";
const languageStorageKey = "inchspace.languagePreference";
const launchEditLongPressMs = 520;
const dockTabsReservedHeight = 82;
const launchGroupGap = 18;
const launchGroupPlacementSearchRadius = 80;
const launchReorderOverlapThreshold = 0.32;
const launchGroupPageClaimThreshold = 8;
const launchGroupPageSwipeThreshold = 42;
const launchGroupWheelPageThreshold = 14;
const launchGroupWheelPageCooldownMs = 360;
const launchGroupTitleHeight = 30;
const rootLaunchGroup = "__inchspace_root__";
const dockGridColumnRange = {
  min: 4,
  max: 12,
};
const dockGridRowRange = {
  min: 3,
  max: 10,
};
const defaultDockGridSettings: DockGridSettings = {
  columns: 8,
  rows: 6,
};
const appWindowMinimumBaseSize = {
  height: 620,
  width: 860,
};
const appShellLayoutMetrics = {
  sidebarWidth: 248,
  workspacePaddingX: 84,
  workspacePaddingY: 68,
};
const launchGroupMetrics = {
  borderSize: 1,
  cellHeight: 108,
  cellWidth: 88,
  gapX: 16,
  gapY: 14,
  maxColumns: 6,
  maxRows: 5,
  minColumns: 1,
  minRows: 1,
  padding: 14,
};
const openLaunchGroupMetrics = {
  columns: 5,
  paddingX: 24,
  paddingY: 22,
  rows: 4,
};
const defaultGroupLayout: LaunchGroupLayout = {
  width: getGroupWidthForColumns(3),
  height: getGroupHeightForRows(2),
  columns: 3,
  iconSize: 58,
  rows: 2,
};

const dockContentTabs: Array<{ id: DockContentTabId; label: Record<AppLanguage, string> }> = [
  {
    id: "programs",
    label: {
      zh: "程序",
      en: "Apps",
    },
  },
  {
    id: "directories",
    label: {
      zh: "目录",
      en: "Folders",
    },
  },
];

const availableLanguages: Array<{ value: AppLanguage; label: string; htmlLang: string }> = [
  { value: "zh", label: "简体中文", htmlLang: "zh-CN" },
  { value: "en", label: "English", htmlLang: "en" },
];

const defaultFloatingBallStyle: FloatingBallStyle = "rotatingGlobe";
const floatingBallMetricsRefreshMs = 1000;
const floatingBallMetricsHistoryLimit = 28;
const defaultSystemMetrics: SystemMetrics = {
  cpuUsage: 0,
  downloadBytesPerSecond: 0,
  memoryTotalBytes: 0,
  memoryUsage: 0,
  memoryUsedBytes: 0,
  uploadBytesPerSecond: 0,
};
const previewMetricsHistory: SystemMetrics[] = [
  {
    ...defaultSystemMetrics,
    cpuUsage: 24,
    downloadBytesPerSecond: 32_000,
    memoryUsage: 42,
    uploadBytesPerSecond: 4_000,
  },
  {
    ...defaultSystemMetrics,
    cpuUsage: 38,
    downloadBytesPerSecond: 180_000,
    memoryUsage: 44,
    uploadBytesPerSecond: 92_000,
  },
  {
    ...defaultSystemMetrics,
    cpuUsage: 44,
    downloadBytesPerSecond: 54_000,
    memoryUsage: 49,
    uploadBytesPerSecond: 18_000,
  },
  {
    ...defaultSystemMetrics,
    cpuUsage: 62,
    downloadBytesPerSecond: 8_400_000,
    memoryUsage: 57,
    uploadBytesPerSecond: 38_000,
  },
  {
    ...defaultSystemMetrics,
    cpuUsage: 54,
    downloadBytesPerSecond: 92_000,
    memoryUsage: 62,
    uploadBytesPerSecond: 12_000,
  },
  {
    ...defaultSystemMetrics,
    cpuUsage: 48,
    downloadBytesPerSecond: 2_600_000,
    memoryUsage: 59,
    uploadBytesPerSecond: 360_000,
  },
  {
    ...defaultSystemMetrics,
    cpuUsage: 36,
    downloadBytesPerSecond: 124_000,
    memoryUsage: 55,
    uploadBytesPerSecond: 26_000,
  },
];

const floatingBallStyleOptions: Array<{
  label: Record<AppLanguage, string>;
  value: FloatingBallStyle;
}> = [
  {
    value: "rotatingGlobe",
    label: {
      zh: "旋转地球",
      en: "Rotating Globe",
    },
  },
  {
    value: "networkSpeed",
    label: {
      zh: "网络速率",
      en: "Network Speed",
    },
  },
  {
    value: "systemPressure",
    label: {
      zh: "系统压力",
      en: "System Pressure",
    },
  },
];

const copy = {
  zh: {
    addDirectory: "添加目录",
    addApp: "添加应用",
    appSidebar: "应用侧栏",
    mainMenu: "主菜单",
    workspace: "工作区",
    collapseSidebar: "折叠侧边栏",
    defaultGroup: "常用",
    deleteApp: "删除应用",
    deleteDirectory: "删除目录",
    directoryAlreadyAdded: "这个目录已经添加过了",
    directoryEmptyTitle: "还没有目录",
    dockEmptyTitle: "还没有启动项",
    group: "分组",
    groupNameEdit: "编辑分组名称",
    gridFull: "页面已满，请先删除一个启动项或移入分组",
    launch: "启动",
    launchFailed: "启动失败，请检查应用",
    languageSetting: "应用语言",
    languageSelector: "选择应用语言",
    dockIconVisibilitySetting: "Dock 图标",
    dockIconVisibilityToggle: "在 Dock 栏显示方寸图标",
    dockIconVisible: "显示",
    dockIconHidden: "隐藏",
    floatingBallStyleSetting: "悬浮球样式",
    dockLayoutSetting: "Dock 布局",
    dockColumns: "列数",
    dockRows: "行数",
    dockGridTooSmall: "当前启动项数量超过这个布局容量",
    followSystem: "跟随系统",
    invalidAppSelection: "请选择受支持的应用程序",
    invalidDirectorySelection: "请选择一个有效目录",
    moveGroup: "移动分组",
    openGroup: "打开分组",
    openDirectory: "打开目录",
    openDirectoryFailed: "打开目录失败，请检查目录是否存在",
    forceShutdown: "强制关机",
    forceShutdownCancel: "取消",
    forceShutdownConfirmMessage:
      "确认后方寸会立即向系统发起强制关机请求，不再逐个退出应用。未保存的内容可能会丢失，请先确认文件已保存。",
    forceShutdownConfirmOk: "立即关机",
    forceShutdownFailed: "强制关机请求失败，请稍后重试或使用系统菜单关机。",
    forceShutdownStarting: "正在发起强制关机...",
    forceShutdownTitle: "确认强制关机",
    resizeGroup: "调整分组大小",
    selectApplication: "选择应用程序",
    selectDirectory: "选择目录",
  },
  en: {
    addDirectory: "Add Folder",
    addApp: "Add App",
    appSidebar: "App sidebar",
    mainMenu: "Main menu",
    workspace: "Workspace",
    collapseSidebar: "Collapse sidebar",
    defaultGroup: "Favorites",
    deleteApp: "Delete app",
    deleteDirectory: "Delete folder",
    directoryAlreadyAdded: "This folder has already been added.",
    directoryEmptyTitle: "No folders yet",
    dockEmptyTitle: "No launch items yet",
    group: "Group",
    groupNameEdit: "Edit group name",
    gridFull: "The page is full. Remove an item or move one into a group.",
    launch: "Launch",
    launchFailed: "Launch failed. Check the application.",
    languageSetting: "App language",
    languageSelector: "Choose app language",
    dockIconVisibilitySetting: "Dock icon",
    dockIconVisibilityToggle: "Show InchSpace in the Dock",
    dockIconVisible: "Shown",
    dockIconHidden: "Hidden",
    floatingBallStyleSetting: "Floating ball style",
    dockLayoutSetting: "Dock layout",
    dockColumns: "Columns",
    dockRows: "Rows",
    dockGridTooSmall: "The current launch items exceed this layout capacity.",
    followSystem: "System",
    invalidAppSelection: "Choose a supported application.",
    invalidDirectorySelection: "Choose a valid folder.",
    moveGroup: "Move group",
    openGroup: "Open group",
    openDirectory: "Open folder",
    openDirectoryFailed: "Could not open this folder. Check that it still exists.",
    forceShutdown: "Force Shut Down",
    forceShutdownCancel: "Cancel",
    forceShutdownConfirmMessage:
      "After confirmation, InchSpace will immediately request a forced system shutdown instead of quitting apps one by one. Unsaved work may be lost.",
    forceShutdownConfirmOk: "Shut Down Now",
    forceShutdownFailed: "Could not request forced shutdown. Try again or use the system menu.",
    forceShutdownStarting: "Requesting forced shutdown...",
    forceShutdownTitle: "Confirm Forced Shutdown",
    resizeGroup: "Resize group",
    selectApplication: "Choose Application",
    selectDirectory: "Choose Folder",
  },
} satisfies Record<AppLanguage, Record<string, string>>;

function isAppLanguage(value: string | null): value is AppLanguage {
  return appLanguages.includes(value as AppLanguage);
}

function isLanguagePreference(value: string | null): value is LanguagePreference {
  return value === "system" || isAppLanguage(value);
}

function isFloatingBallStyle(value: string | null): value is FloatingBallStyle {
  return floatingBallStyles.includes(value as FloatingBallStyle);
}

function getCurrentWindowLabel(): string {
  return (
    (globalThis as typeof globalThis & { __TAURI_INTERNALS__?: TauriInternals })
      .__TAURI_INTERNALS__?.metadata?.currentWindow?.label ?? mainWindowLabel
  );
}

function syncDocumentWindowLabel(windowLabel: string): void {
  if (typeof document === "undefined") {
    return;
  }

  document.documentElement.dataset.window =
    windowLabel === floatingBallWindowLabel ? floatingBallWindowLabel : mainWindowLabel;
}

function getClientPlatform(): ClientPlatform {
  if (typeof navigator === "undefined") {
    return "other";
  }

  const navigatorWithUserAgentData = navigator as NavigatorWithUserAgentData;
  const platformText = [
    navigatorWithUserAgentData.userAgentData?.platform,
    navigator.platform,
    navigator.userAgent,
  ]
    .filter(Boolean)
    .join(" ");

  if (/windows|win32|win64/i.test(platformText)) {
    return "windows";
  }

  if (/mac|darwin/i.test(platformText)) {
    return "macos";
  }

  if (/linux|x11/i.test(platformText)) {
    return "linux";
  }

  return "other";
}

function syncDocumentPlatform(): void {
  if (typeof document === "undefined") {
    return;
  }

  document.documentElement.dataset.platform = getClientPlatform();
}

function getStoredLanguagePreference(): LanguagePreference {
  try {
    const storedPreference = window.localStorage.getItem(languageStorageKey);
    return isLanguagePreference(storedPreference) ? storedPreference : "system";
  } catch {
    return "system";
  }
}

function getStoredFloatingBallStyle(): FloatingBallStyle {
  try {
    const storedStyle = window.localStorage.getItem(floatingBallStyleStorageKey);
    return isFloatingBallStyle(storedStyle) ? storedStyle : defaultFloatingBallStyle;
  } catch {
    return defaultFloatingBallStyle;
  }
}

function getStoredDockIconVisible(): boolean {
  try {
    return window.localStorage.getItem(dockIconVisibleStorageKey) !== "false";
  } catch {
    return true;
  }
}

function createId(prefix: string): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return `${prefix}-${crypto.randomUUID()}`;
  }

  return `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

function clampNumber(value: unknown, min: number, max: number, fallback: number): number {
  if (typeof value !== "number" || Number.isNaN(value)) {
    return fallback;
  }

  return Math.min(Math.max(value, min), max);
}

function clampInteger(value: number, min: number, max: number): number {
  return Math.min(Math.max(Math.round(value), min), max);
}

function isMetricFloatingBallStyle(style: FloatingBallStyle): boolean {
  return style === "networkSpeed" || style === "systemPressure";
}

function normalizeMetricNumber(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function normalizeSystemMetrics(value: unknown): SystemMetrics {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return defaultSystemMetrics;
  }

  const metrics = value as Partial<SystemMetrics>;

  return {
    cpuUsage: clampNumber(metrics.cpuUsage, 0, 100, defaultSystemMetrics.cpuUsage),
    downloadBytesPerSecond: Math.max(
      normalizeMetricNumber(metrics.downloadBytesPerSecond),
      0,
    ),
    memoryTotalBytes: Math.max(Math.round(normalizeMetricNumber(metrics.memoryTotalBytes)), 0),
    memoryUsage: clampNumber(metrics.memoryUsage, 0, 100, defaultSystemMetrics.memoryUsage),
    memoryUsedBytes: Math.max(Math.round(normalizeMetricNumber(metrics.memoryUsedBytes)), 0),
    uploadBytesPerSecond: Math.max(
      normalizeMetricNumber(metrics.uploadBytesPerSecond),
      0,
    ),
  };
}

function getLatestSystemMetrics(metricsHistory: SystemMetrics[]): SystemMetrics {
  return metricsHistory[metricsHistory.length - 1] ?? defaultSystemMetrics;
}

function getDirectionalSparklinePoints(
  values: number[],
  width: number,
  baseline: number,
  amplitude: number,
  direction: "down" | "up",
  scaleMax: number,
): string {
  if (values.length === 0) {
    return "";
  }

  const maxValue = Math.max(scaleMax, 1);
  const lastIndex = Math.max(values.length - 1, 1);

  return values
    .map((value, index) => {
      const x = (index / lastIndex) * width;
      const offset = (Math.max(value, 0) / maxValue) * amplitude;
      const y = direction === "up" ? baseline - offset : baseline + offset;

      return `${x.toFixed(2)},${y.toFixed(2)}`;
    })
    .join(" ");
}

function getDirectionalSparklineAreaPoints(
  values: number[],
  width: number,
  baseline: number,
  amplitude: number,
  direction: "down" | "up",
  scaleMax: number,
): string {
  const linePoints = getDirectionalSparklinePoints(
    values,
    width,
    baseline,
    amplitude,
    direction,
    scaleMax,
  );

  return linePoints ? `0,${baseline} ${linePoints} ${width},${baseline}` : "";
}

function getBytesPerSecondDisplay(value: number): { unit: string; value: string } {
  const safeValue = Math.max(value, 0);

  if (safeValue >= 1024 * 1024) {
    return {
      unit: "M",
      value: `${Math.round(safeValue / 1024 / 1024)}`,
    };
  }

  if (safeValue >= 1024) {
    return {
      unit: "K",
      value: `${Math.round(safeValue / 1024)}`,
    };
  }

  return {
    unit: "B",
    value: `${Math.round(safeValue)}`,
  };
}

function normalizeDockGridSettings(value: unknown): DockGridSettings {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return defaultDockGridSettings;
  }

  const settings = value as Partial<DockGridSettings>;

  return {
    columns: clampInteger(
      clampNumber(
        settings.columns,
        dockGridColumnRange.min,
        dockGridColumnRange.max,
        defaultDockGridSettings.columns,
      ),
      dockGridColumnRange.min,
      dockGridColumnRange.max,
    ),
    rows: clampInteger(
      clampNumber(
        settings.rows,
        dockGridRowRange.min,
        dockGridRowRange.max,
        defaultDockGridSettings.rows,
      ),
      dockGridRowRange.min,
      dockGridRowRange.max,
    ),
  };
}

function getStoredDockGridSettings(): DockGridSettings {
  try {
    return normalizeDockGridSettings(
      JSON.parse(window.localStorage.getItem(dockGridSettingsStorageKey) ?? "null"),
    );
  } catch {
    return defaultDockGridSettings;
  }
}

function getGroupChromeSize(): number {
  return 0;
}

function getTrackSize(trackCount: number, cellSize: number, gapSize: number): number {
  return trackCount * cellSize + Math.max(trackCount - 1, 0) * gapSize;
}

function getRootLaunchGridCapacity(dockGridSettings: DockGridSettings): number {
  return dockGridSettings.columns * dockGridSettings.rows;
}

function getRootLaunchGridWidth(dockGridSettings: DockGridSettings = defaultDockGridSettings): number {
  return launchGroupMetrics.padding * 2 + getTrackSize(
    dockGridSettings.columns,
    launchGroupMetrics.cellWidth,
    launchGroupMetrics.gapX,
  );
}

function getRootLaunchGridHeight(dockGridSettings: DockGridSettings = defaultDockGridSettings): number {
  return launchGroupMetrics.padding * 2 + getTrackSize(
    dockGridSettings.rows,
    launchGroupMetrics.cellHeight,
    launchGroupMetrics.gapY,
  );
}

function getDockWindowMinimumSize(dockGridSettings: DockGridSettings): { height: number; width: number } {
  return {
    height: Math.ceil(
      Math.max(
        appWindowMinimumBaseSize.height,
        appShellLayoutMetrics.workspacePaddingY +
          dockTabsReservedHeight +
          getRootLaunchGridHeight(dockGridSettings),
      ),
    ),
    width: Math.ceil(
      Math.max(
        appWindowMinimumBaseSize.width,
        appShellLayoutMetrics.sidebarWidth +
          appShellLayoutMetrics.workspacePaddingX +
          getRootLaunchGridWidth(dockGridSettings),
      ),
    ),
  };
}

async function syncDockWindowMinimumSize(dockGridSettings: DockGridSettings): Promise<void> {
  const minimumSize = getDockWindowMinimumSize(dockGridSettings);
  const appWindow = getCurrentWindow();

  await appWindow.setMinSize(new LogicalSize(minimumSize.width, minimumSize.height));

  const [innerSize, scaleFactor] = await Promise.all([
    appWindow.innerSize(),
    appWindow.scaleFactor(),
  ]);
  const currentLogicalSize = {
    height: innerSize.height / scaleFactor,
    width: innerSize.width / scaleFactor,
  };
  const nextWidth = Math.max(currentLogicalSize.width, minimumSize.width);
  const nextHeight = Math.max(currentLogicalSize.height, minimumSize.height);

  if (nextWidth !== currentLogicalSize.width || nextHeight !== currentLogicalSize.height) {
    await appWindow.setSize(new LogicalSize(nextWidth, nextHeight));
  }
}

function getGroupWidthForColumns(columnCount: number): number {
  const columns = clampInteger(
    columnCount,
    launchGroupMetrics.minColumns,
    launchGroupMetrics.maxColumns,
  );

  return getGroupChromeSize() + getTrackSize(columns, launchGroupMetrics.cellWidth, launchGroupMetrics.gapX);
}

function getGroupHeightForRows(rowCount: number): number {
  const rows = clampInteger(rowCount, launchGroupMetrics.minRows, launchGroupMetrics.maxRows);

  return (
    launchGroupTitleHeight +
    getGroupChromeSize() +
    getTrackSize(rows, launchGroupMetrics.cellHeight, launchGroupMetrics.gapY)
  );
}

function getGroupRowsFromLayout(layout: LaunchGroupLayout): number {
  return getTrackCountFromSize(
    layout.height,
    launchGroupMetrics.cellHeight,
    launchGroupMetrics.gapY,
    launchGroupMetrics.minRows,
    launchGroupMetrics.maxRows,
    1,
    launchGroupTitleHeight,
  );
}

function getLaunchGroupPageCapacity(layout: LaunchGroupLayout): number {
  return Math.max(layout.columns * (layout.rows ?? getGroupRowsFromLayout(layout)), 1);
}

function getLaunchGroupPageCount(itemCount: number, layout: LaunchGroupLayout): number {
  return Math.max(Math.ceil(itemCount / getLaunchGroupPageCapacity(layout)), 1);
}

function clampLaunchGroupPage(
  page: number,
  itemCount: number,
  layout: LaunchGroupLayout,
): number {
  return clampInteger(page, 0, getLaunchGroupPageCount(itemCount, layout) - 1);
}

function getLaunchGroupPageItems(
  items: LaunchItem[],
  page: number,
  layout: LaunchGroupLayout,
): LaunchItem[] {
  const pageCapacity = getLaunchGroupPageCapacity(layout);
  const startIndex = clampLaunchGroupPage(page, items.length, layout) * pageCapacity;

  return items.slice(startIndex, startIndex + pageCapacity);
}

function getLaunchGroupPagedItems(
  items: LaunchItem[],
  layout: LaunchGroupLayout,
): LaunchItem[][] {
  return Array.from(
    { length: getLaunchGroupPageCount(items.length, layout) },
    (_, pageIndex) => getLaunchGroupPageItems(items, pageIndex, layout),
  );
}

function getTrackCountFromSize(
  value: unknown,
  cellSize: number,
  gapSize: number,
  min: number,
  max: number,
  fallback: number,
  chromeSize = getGroupChromeSize(),
): number {
  if (typeof value !== "number" || Number.isNaN(value)) {
    return fallback;
  }

  const trackSpace = value - chromeSize;
  const trackCount = (trackSpace + gapSize) / (cellSize + gapSize);

  return clampInteger(trackCount, min, max);
}

function snapGroupWidth(value: unknown): number {
  return getGroupWidthForColumns(
    getTrackCountFromSize(
      value,
      launchGroupMetrics.cellWidth,
      launchGroupMetrics.gapX,
      launchGroupMetrics.minColumns,
      launchGroupMetrics.maxColumns,
      3,
    ),
  );
}

function snapGroupHeight(value: unknown): number {
  return getGroupHeightForRows(
    getTrackCountFromSize(
      value,
      launchGroupMetrics.cellHeight,
      launchGroupMetrics.gapY,
      launchGroupMetrics.minRows,
      launchGroupMetrics.maxRows,
      2,
      launchGroupTitleHeight,
    ),
  );
}

function normalizeGroupLayout(layout: Partial<LaunchGroupLayout>): LaunchGroupLayout {
  const width = snapGroupWidth(layout.width);
  const height = snapGroupHeight(layout.height);
  const position = normalizeLaunchPosition(layout.position);
  const columns = getTrackCountFromSize(
    width,
    launchGroupMetrics.cellWidth,
    launchGroupMetrics.gapX,
    launchGroupMetrics.minColumns,
    launchGroupMetrics.maxColumns,
    defaultGroupLayout.columns,
  );

  return {
    width,
    height,
    columns,
    iconSize: clampNumber(layout.iconSize, 44, 88, defaultGroupLayout.iconSize),
    manualPosition: layout.manualPosition === true && Boolean(position),
    manualSize: layout.manualSize === true,
    position,
    rows: getGroupRowsFromLayout({ ...defaultGroupLayout, height, width, columns }),
  };
}

function normalizeLaunchPosition(value: unknown): LaunchPosition | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return undefined;
  }

  const position = value as LaunchPosition;

  if (
    typeof position.x !== "number" ||
    Number.isNaN(position.x) ||
    typeof position.y !== "number" ||
    Number.isNaN(position.y)
  ) {
    return undefined;
  }

  return {
    x: Math.max(position.x, 0),
    y: Math.max(position.y, 0),
  };
}

function normalizeSortOrder(value: unknown): number | undefined {
  return typeof value === "number" && !Number.isNaN(value) ? value : undefined;
}

function normalizeLaunchItems(value: unknown): LaunchItem[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.flatMap((item): LaunchItem[] => {
    if (
      typeof item !== "object" ||
      item === null ||
      typeof (item as LaunchItem).id !== "string" ||
      typeof (item as LaunchItem).name !== "string" ||
      typeof (item as LaunchItem).path !== "string" ||
      typeof (item as LaunchItem).group !== "string"
    ) {
      return [];
    }

    return [
      {
        id: (item as LaunchItem).id,
        name: (item as LaunchItem).name,
        path: (item as LaunchItem).path,
        iconDataUrl:
          typeof (item as LaunchItem).iconDataUrl === "string" &&
          (item as LaunchItem).iconDataUrl?.trim()
            ? (item as LaunchItem).iconDataUrl
            : undefined,
        group: (item as LaunchItem).group,
        createdAt:
          typeof (item as LaunchItem).createdAt === "number"
            ? (item as LaunchItem).createdAt
            : Date.now(),
        position: normalizeLaunchPosition((item as LaunchItem).position),
        sortOrder: normalizeSortOrder((item as LaunchItem).sortOrder),
      },
    ];
  });
}

function getStoredLaunchItems(): LaunchItem[] {
  try {
    return normalizeLaunchItems(JSON.parse(window.localStorage.getItem(launchItemsStorageKey) ?? "[]"));
  } catch {
    return [];
  }
}

function getPathDisplayName(path: string): string {
  const trimmedPath = path.trim();
  const normalizedPath = trimmedPath.replace(/[\\/]+$/, "");
  const segments = normalizedPath.split(/[\\/]/).filter(Boolean);

  return segments[segments.length - 1] ?? trimmedPath;
}

function normalizeComparablePath(path: string): string {
  return path.trim().replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
}

function getDirectoryComparisonPath(item: { comparisonPath?: string | null; path: string }): string {
  return normalizeComparablePath(item.comparisonPath?.trim() || item.path);
}

function isSameDirectoryItem(
  first: { comparisonPath?: string | null; path: string },
  second: { comparisonPath?: string | null; path: string },
): boolean {
  return getDirectoryComparisonPath(first) === getDirectoryComparisonPath(second);
}

function normalizeDirectoryItems(value: unknown): DirectoryItem[] {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.flatMap((item): DirectoryItem[] => {
    if (
      typeof item !== "object" ||
      item === null ||
      typeof (item as DirectoryItem).id !== "string" ||
      typeof (item as DirectoryItem).name !== "string" ||
      typeof (item as DirectoryItem).path !== "string"
    ) {
      return [];
    }

    const name = (item as DirectoryItem).name.trim() || getPathDisplayName((item as DirectoryItem).path);

    return [
      {
        id: (item as DirectoryItem).id,
        name,
        path: (item as DirectoryItem).path,
        comparisonPath:
          typeof (item as DirectoryItem).comparisonPath === "string" &&
          (item as DirectoryItem).comparisonPath?.trim()
            ? (item as DirectoryItem).comparisonPath
            : undefined,
        iconDataUrl:
          typeof (item as DirectoryItem).iconDataUrl === "string" &&
          (item as DirectoryItem).iconDataUrl?.trim()
            ? (item as DirectoryItem).iconDataUrl
            : undefined,
        createdAt:
          typeof (item as DirectoryItem).createdAt === "number"
            ? (item as DirectoryItem).createdAt
            : Date.now(),
        position: normalizeLaunchPosition((item as DirectoryItem).position),
        sortOrder: normalizeSortOrder((item as DirectoryItem).sortOrder),
      },
    ];
  });
}

function getStoredDirectoryItems(): DirectoryItem[] {
  try {
    return normalizeDirectoryItems(
      JSON.parse(window.localStorage.getItem(directoryItemsStorageKey) ?? "[]"),
    );
  } catch {
    return [];
  }
}

function getPngDataUrlSize(dataUrl: string): { height: number; width: number } | null {
  const prefix = "data:image/png;base64,";
  const value = dataUrl.trim();

  if (!value.startsWith(prefix)) {
    return null;
  }

  try {
    const binary = window.atob(value.slice(prefix.length));

    if (
      binary.length < 24 ||
      binary.charCodeAt(0) !== 0x89 ||
      binary.slice(1, 4) !== "PNG"
    ) {
      return null;
    }

    const readU32 = (offset: number) =>
      binary.charCodeAt(offset) * 0x1000000 +
      binary.charCodeAt(offset + 1) * 0x10000 +
      binary.charCodeAt(offset + 2) * 0x100 +
      binary.charCodeAt(offset + 3);

    return {
      width: readU32(16),
      height: readU32(20),
    };
  } catch {
    return null;
  }
}

function shouldRefreshIconDataUrl(iconDataUrl?: string): boolean {
  if (!iconDataUrl?.trim()) {
    return true;
  }

  const pngSize = getPngDataUrlSize(iconDataUrl);

  return !pngSize || Math.max(pngSize.width, pngSize.height) < 128;
}

function shouldRefreshDirectoryMetadata(item: DirectoryItem): boolean {
  return (
    !item.comparisonPath?.trim() ||
    item.path.includes("/Library/Mobile Documents/") ||
    shouldRefreshIconDataUrl(item.iconDataUrl)
  );
}

function normalizeGroupLayouts(value: unknown): Record<string, LaunchGroupLayout> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return {};
  }

  return Object.entries(value).reduce<Record<string, LaunchGroupLayout>>((layouts, [group, layout]) => {
    if (typeof layout !== "object" || layout === null || Array.isArray(layout)) {
      return layouts;
    }

    layouts[group] = normalizeGroupLayout(layout as Partial<LaunchGroupLayout>);

    return layouts;
  }, {});
}

function getStoredGroupLayouts(): Record<string, LaunchGroupLayout> {
  try {
    return normalizeGroupLayouts(
      JSON.parse(window.localStorage.getItem(launchGroupLayoutsStorageKey) ?? "{}"),
    );
  } catch {
    return {};
  }
}

function normalizeLaunchGroupNames(value: unknown): Record<string, string> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return {};
  }

  return Object.entries(value).reduce<Record<string, string>>((names, [groupName, displayName]) => {
    if (typeof groupName !== "string" || typeof displayName !== "string") {
      return names;
    }

    const trimmedDisplayName = displayName.trim();

    if (trimmedDisplayName) {
      names[groupName] = trimmedDisplayName.slice(0, 48);
    }

    return names;
  }, {});
}

function getStoredLaunchGroupNames(): Record<string, string> {
  try {
    return normalizeLaunchGroupNames(
      JSON.parse(window.localStorage.getItem(launchGroupNamesStorageKey) ?? "{}"),
    );
  } catch {
    return {};
  }
}

function getIconLabel(name: string): string {
  const label = name.trim();
  return label.slice(0, 2).toUpperCase() || "?";
}

function getIconPalette(name: string): [string, string] {
  const palettes: Array<[string, string]> = [
    ["#0ea5a4", "#0f766e"],
    ["#3b82f6", "#1d4ed8"],
    ["#f97316", "#c2410c"],
    ["#8b5cf6", "#6d28d9"],
    ["#14b8a6", "#047857"],
    ["#f43f5e", "#be123c"],
  ];
  const seed = [...name].reduce((total, character) => total + character.charCodeAt(0), 0);

  return palettes[seed % palettes.length];
}

function getSystemLanguage(): AppLanguage {
  const languages = navigator.languages.length > 0 ? navigator.languages : [navigator.language];
  return languages.some((language) => language.toLowerCase().startsWith("zh")) ? "zh" : "en";
}

function isDefaultLaunchGroupName(groupName: string): boolean {
  return Object.values(copy).some((languageCopy) => languageCopy.defaultGroup === groupName);
}

function isRootLaunchGroupName(groupName: string): boolean {
  const trimmedGroupName = groupName.trim();

  return !trimmedGroupName || trimmedGroupName === rootLaunchGroup || isDefaultLaunchGroupName(trimmedGroupName);
}

function getLaunchGroupKey(groupName: string): string {
  return isRootLaunchGroupName(groupName) ? rootLaunchGroup : groupName.trim();
}

function getLaunchSortOrder(item: { createdAt: number; sortOrder?: number }): number {
  return item.sortOrder ?? item.createdAt;
}

function sortLaunchItems(first: LaunchItem, second: LaunchItem): number {
  return getLaunchSortOrder(first) - getLaunchSortOrder(second) || first.createdAt - second.createdAt;
}

function sortDirectoryItems(first: DirectoryItem, second: DirectoryItem): number {
  return getLaunchSortOrder(first) - getLaunchSortOrder(second) || first.createdAt - second.createdAt;
}

function getNextGroupSortOrder(items: LaunchItem[], groupKey: string): number {
  const groupOrders = items
    .filter((item) => getLaunchGroupKey(item.group) === groupKey)
    .map(getLaunchSortOrder);

  return groupOrders.length > 0 ? Math.max(...groupOrders) + 1 : 0;
}

function getRootLaunchGridCoordinates(
  position: LaunchPosition,
  dockGridSettings: DockGridSettings,
): { column: number; row: number } {
  const columnStep = launchGroupMetrics.cellWidth + launchGroupMetrics.gapX;
  const rowStep = launchGroupMetrics.cellHeight + launchGroupMetrics.gapY;

  return {
    column: clampInteger(
      (position.x - launchGroupMetrics.padding) / columnStep,
      0,
      dockGridSettings.columns - 1,
    ),
    row: clampInteger(
      (position.y - launchGroupMetrics.padding) / rowStep,
      0,
      dockGridSettings.rows - 1,
    ),
  };
}

function getRootLaunchPositionFromGrid(
  column: number,
  row: number,
  dockGridSettings: DockGridSettings,
): LaunchPosition {
  const columnStep = launchGroupMetrics.cellWidth + launchGroupMetrics.gapX;
  const rowStep = launchGroupMetrics.cellHeight + launchGroupMetrics.gapY;
  const clampedColumn = clampInteger(column, 0, dockGridSettings.columns - 1);
  const clampedRow = clampInteger(row, 0, dockGridSettings.rows - 1);

  return {
    x: launchGroupMetrics.padding + clampedColumn * columnStep,
    y: launchGroupMetrics.padding + clampedRow * rowStep,
  };
}

function getFallbackRootLaunchPosition(
  index: number,
  dockGridSettings: DockGridSettings,
): LaunchPosition {
  const gridIndex = clampInteger(index, 0, getRootLaunchGridCapacity(dockGridSettings) - 1);

  return getRootLaunchPositionFromGrid(
    gridIndex % dockGridSettings.columns,
    Math.floor(gridIndex / dockGridSettings.columns),
    dockGridSettings,
  );
}

function getRootLaunchPositionKey(
  position: LaunchPosition,
  dockGridSettings: DockGridSettings,
): string {
  const coordinates = getRootLaunchGridCoordinates(position, dockGridSettings);

  return `${coordinates.column}:${coordinates.row}`;
}

function getRootLaunchGridIndex(
  position: LaunchPosition,
  dockGridSettings: DockGridSettings,
): number {
  const coordinates = getRootLaunchGridCoordinates(position, dockGridSettings);

  return coordinates.row * dockGridSettings.columns + coordinates.column;
}

function getRootEntryPreferredPosition(
  entry: LaunchRootEntry,
  fallbackIndex: number,
  dockGridSettings: DockGridSettings,
  groupLayouts: Record<string, LaunchGroupLayout>,
): LaunchPosition {
  if (entry.kind === "item") {
    return getRootLaunchItemPosition(entry.item, fallbackIndex, dockGridSettings);
  }

  const layoutPosition = groupLayouts[entry.group.name]?.position;

  return layoutPosition
    ? snapRootLaunchPosition(layoutPosition, dockGridSettings)
    : getFallbackRootLaunchPosition(fallbackIndex, dockGridSettings);
}

function getRootEntriesInGridOrder(
  entries: LaunchRootEntry[],
  dockGridSettings: DockGridSettings,
  groupLayouts: Record<string, LaunchGroupLayout>,
): LaunchRootEntry[] {
  return entries
    .map((entry, index) => {
      const position = getRootEntryPreferredPosition(
        entry,
        index,
        dockGridSettings,
        groupLayouts,
      );

      return {
        entry,
        gridIndex: getRootLaunchGridIndex(position, dockGridSettings),
        index,
        position,
      };
    })
    .sort(
      (first, second) =>
        first.gridIndex - second.gridIndex ||
        first.position.y - second.position.y ||
        first.position.x - second.position.x ||
        first.index - second.index,
    )
    .map(({ entry }) => entry);
}

function getRootEntriesWithInsertedItem(
  entries: LaunchRootEntry[],
  movingItem: LaunchItem,
  target: LaunchRootInsertionTarget,
  dockGridSettings: DockGridSettings,
  groupLayouts: Record<string, LaunchGroupLayout>,
): LaunchRootEntry[] | null {
  const orderedEntries = getRootEntriesInGridOrder(entries, dockGridSettings, groupLayouts);
  const entriesWithoutMovingItem = orderedEntries.filter(
    (entry) => !(entry.kind === "item" && entry.item.id === movingItem.id),
  );
  const insertIndex =
    target.kind === "entry"
      ? entriesWithoutMovingItem.findIndex((entry) => entry.id === target.entryId) +
        (target.insertAfter ? 1 : 0)
      : target.index;

  if (target.kind === "entry" && insertIndex < (target.insertAfter ? 1 : 0)) {
    return null;
  }

  const clampedInsertIndex = clampInteger(insertIndex, 0, entriesWithoutMovingItem.length);
  const nextEntries = [
    ...entriesWithoutMovingItem.slice(0, clampedInsertIndex),
    {
      id: movingItem.id,
      item: movingItem,
      kind: "item" as const,
    },
    ...entriesWithoutMovingItem.slice(clampedInsertIndex),
  ];

  return nextEntries.length <= getRootLaunchGridCapacity(dockGridSettings) ? nextEntries : null;
}

function getRootEntryPositionsFromOrder(
  entries: LaunchRootEntry[],
  dockGridSettings: DockGridSettings,
): ResolvedRootEntryPositions {
  const groups = new Map<string, LaunchPosition>();
  const items = new Map<string, LaunchPosition>();

  entries.forEach((entry, index) => {
    const position = getFallbackRootLaunchPosition(index, dockGridSettings);

    if (entry.kind === "item") {
      items.set(entry.item.id, position);
      return;
    }

    groups.set(entry.group.name, position);
  });

  return {
    groups,
    items,
  };
}

function getNearestAvailableRootLaunchPosition(
  occupiedPositions: Set<string>,
  preferredPosition: LaunchPosition,
  dockGridSettings: DockGridSettings,
): LaunchPosition | null {
  const preferredCoordinates = getRootLaunchGridCoordinates(preferredPosition, dockGridSettings);
  const candidates = Array.from({ length: getRootLaunchGridCapacity(dockGridSettings) }, (_, index) => {
    const column = index % dockGridSettings.columns;
    const row = Math.floor(index / dockGridSettings.columns);

    return {
      column,
      distance: Math.hypot(
        column - preferredCoordinates.column,
        row - preferredCoordinates.row,
      ),
      row,
    };
  }).sort(
    (first, second) =>
      first.distance - second.distance ||
      first.row - second.row ||
      first.column - second.column,
  );

  for (const candidate of candidates) {
    const position = getRootLaunchPositionFromGrid(candidate.column, candidate.row, dockGridSettings);
    const key = getRootLaunchPositionKey(position, dockGridSettings);

    if (!occupiedPositions.has(key)) {
      return position;
    }
  }

  return null;
}

function normalizeRootLaunchPositions(
  items: LaunchItem[],
  dockGridSettings: DockGridSettings,
  preferredPositions: Map<string, LaunchPosition> = new Map(),
): LaunchItem[] {
  const occupiedPositions = new Set<string>();
  const rootItems = items.filter((item) => getLaunchGroupKey(item.group) === rootLaunchGroup).sort(sortLaunchItems);
  const assignedPositions = new Map<string, LaunchPosition>();

  rootItems.forEach((item, index) => {
    const preferredPosition =
      preferredPositions.get(item.id) ??
      item.position ??
      getFallbackRootLaunchPosition(index, dockGridSettings);
    const position = getNearestAvailableRootLaunchPosition(
      occupiedPositions,
      preferredPosition,
      dockGridSettings,
    );

    if (position) {
      occupiedPositions.add(getRootLaunchPositionKey(position, dockGridSettings));
      assignedPositions.set(item.id, position);
    }
  });

  return items.map((item) => {
    const position = assignedPositions.get(item.id);

    return position
      ? {
          ...item,
          position,
        }
      : item;
  });
}

function normalizeRootDirectoryPositions(
  items: DirectoryItem[],
  dockGridSettings: DockGridSettings,
  preferredPositions: Map<string, LaunchPosition> = new Map(),
): DirectoryItem[] {
  const occupiedPositions = new Set<string>();
  const assignedPositions = new Map<string, LaunchPosition>();

  [...items].sort(sortDirectoryItems).forEach((item, index) => {
    const preferredPosition =
      preferredPositions.get(item.id) ??
      item.position ??
      getFallbackRootLaunchPosition(index, dockGridSettings);
    const position = getNearestAvailableRootLaunchPosition(
      occupiedPositions,
      preferredPosition,
      dockGridSettings,
    );

    if (position) {
      occupiedPositions.add(getRootLaunchPositionKey(position, dockGridSettings));
      assignedPositions.set(item.id, position);
    }
  });

  return items.map((item) => {
    const position = assignedPositions.get(item.id);

    return position
      ? {
          ...item,
          position,
        }
      : item;
  });
}

function getGroupLayoutForColumns(itemCount: number, columnCount: number): LaunchGroupLayout {
  const safeItemCount = Math.max(itemCount, 1);
  const columns = clampInteger(
    Math.min(Math.max(columnCount, launchGroupMetrics.minColumns), safeItemCount),
    launchGroupMetrics.minColumns,
    launchGroupMetrics.maxColumns,
  );
  const rows = clampInteger(
    Math.ceil(safeItemCount / columns),
    launchGroupMetrics.minRows,
    launchGroupMetrics.maxRows,
  );

  return {
    width: getGroupWidthForColumns(columns),
    height: getGroupHeightForRows(rows),
    columns,
    iconSize: defaultGroupLayout.iconSize,
    rows,
  };
}

function getAutoGroupLayout(itemCount: number): LaunchGroupLayout {
  const safeItemCount = Math.max(itemCount, 1);
  const columns = clampInteger(
    Math.max(Math.min(safeItemCount, launchGroupMetrics.maxColumns), launchGroupMetrics.minColumns),
    launchGroupMetrics.minColumns,
    launchGroupMetrics.maxColumns,
  );

  return getGroupLayoutForColumns(safeItemCount, columns);
}

function getOpenLaunchGroupBaseLayout(
  _itemCount: number,
): LaunchGroupLayout {
  const columns = openLaunchGroupMetrics.columns;
  const rows = openLaunchGroupMetrics.rows;
  const width =
    getTrackSize(columns, launchGroupMetrics.cellWidth, launchGroupMetrics.gapX) +
    openLaunchGroupMetrics.paddingX * 2;
  const height =
    launchGroupTitleHeight +
    getTrackSize(rows, launchGroupMetrics.cellHeight, launchGroupMetrics.gapY) +
    openLaunchGroupMetrics.paddingY * 2;

  return {
    width,
    height,
    columns,
    iconSize: defaultGroupLayout.iconSize,
    manualPosition: false,
    manualSize: false,
    rows,
  };
}

function createLaunchRect(left: number, top: number, width: number, height: number): LaunchRect {
  return {
    bottom: top + height,
    height,
    left,
    right: left + width,
    top,
    width,
  };
}

function getLaunchRectFromDomRect(rect: DOMRect): LaunchRect {
  return createLaunchRect(rect.left, rect.top, rect.width, rect.height);
}

function createLaunchRectFromPosition(
  position: LaunchPosition,
  width: number,
  height: number,
): LaunchRect {
  return createLaunchRect(position.x, position.y, width, height);
}

function getLaunchRootFlowWidth(): number {
  return 0;
}

function getDragLaunchIconRect(x: number, y: number): LaunchRect {
  const iconSize = defaultGroupLayout.iconSize;

  return createLaunchRect(x - iconSize / 2, y - iconSize / 2, iconSize, iconSize);
}

function getLaunchItemIconRect(element: HTMLElement): LaunchRect {
  return getLaunchRectFromDomRect(
    (element.querySelector<HTMLElement>(".launch-app-icon") ?? element).getBoundingClientRect(),
  );
}

function getLaunchRectArea(rect: LaunchRect): number {
  return Math.max(rect.width, 0) * Math.max(rect.height, 0);
}

function getLaunchRectIntersectionArea(first: LaunchRect, second: LaunchRect): number {
  const width = Math.max(Math.min(first.right, second.right) - Math.max(first.left, second.left), 0);
  const height = Math.max(Math.min(first.bottom, second.bottom) - Math.max(first.top, second.top), 0);

  return width * height;
}

function getLaunchColumnStep(): number {
  return launchGroupMetrics.cellWidth + launchGroupMetrics.gapX;
}

function getLaunchRowStep(): number {
  return launchGroupMetrics.cellHeight + launchGroupMetrics.gapY;
}

function getLaunchOverlapRatio(dragRect: LaunchRect, targetRect: LaunchRect): number {
  return getLaunchRectIntersectionArea(dragRect, targetRect) / Math.max(getLaunchRectArea(targetRect), 1);
}

function shouldInsertAfterLaunchTargetRect(dragRect: LaunchRect, targetRect: LaunchRect): boolean {
  const dragCenterX = dragRect.left + dragRect.width / 2;
  const dragCenterY = dragRect.top + dragRect.height / 2;
  const targetCenterX = targetRect.left + targetRect.width / 2;
  const targetCenterY = targetRect.top + targetRect.height / 2;
  const deltaX = dragCenterX - targetCenterX;
  const deltaY = dragCenterY - targetCenterY;

  return Math.abs(deltaX) >= Math.abs(deltaY) ? deltaX > 0 : deltaY > 0;
}

function getLaunchTargetPlacementFromPoint(
  itemId: string,
  x: number,
  y: number,
): Pick<LaunchDropIntent, "insertAfterTarget" | "targetId"> | null {
  const dragRect = getDragLaunchIconRect(x, y);
  const bestTarget = [...document.querySelectorAll<HTMLElement>("[data-launch-item-id]")]
    .filter((element) => element.dataset.launchItemId && element.dataset.launchItemId !== itemId)
    .map((element) => {
      const targetRect = getLaunchItemIconRect(element);
      const overlapRatio = getLaunchOverlapRatio(dragRect, targetRect);

      return {
        element,
        overlapRatio,
        targetRect,
      };
    })
    .filter((target) => target.overlapRatio >= launchReorderOverlapThreshold)
    .sort((first, second) => second.overlapRatio - first.overlapRatio)[0];

  if (!bestTarget?.element.dataset.launchItemId) {
    return null;
  }

  return {
    insertAfterTarget: shouldInsertAfterLaunchTargetRect(dragRect, bestTarget.targetRect),
    targetId: bestTarget.element.dataset.launchItemId,
  };
}

function isDragOverLaunchItemSlot(itemId: string, x: number, y: number): boolean {
  const dragRect = getDragLaunchIconRect(x, y);

  return [...document.querySelectorAll<HTMLElement>("[data-launch-item-id]")]
    .filter((element) => element.dataset.launchItemId === itemId)
    .some(
      (element) =>
        getLaunchOverlapRatio(dragRect, getLaunchItemIconRect(element)) >=
        launchReorderOverlapThreshold * 0.65,
    );
}

function getLaunchGroupElementBelowPoint(x: number, y: number): HTMLElement | null {
  return (
    document
      .elementsFromPoint(x, y)
      .map((element) => element.closest<HTMLElement>("[data-launch-group-name]"))
      .find((groupElement) => groupElement?.dataset.launchGroupName) ?? null
  );
}

function getLaunchRootZoneBelowPoint(x: number, y: number): HTMLElement | null {
  return (
    document
      .elementsFromPoint(x, y)
      .map((element) => element.closest<HTMLElement>("[data-launch-root-zone]"))
      .find(Boolean) ?? null
  );
}

function isPointOutsideOpenLaunchGroupPanel(x: number, y: number): boolean {
  const openPanel = document.querySelector<HTMLElement>(".launch-group.open-panel");

  if (!openPanel) {
    return false;
  }

  const panelRect = openPanel.getBoundingClientRect();

  return x < panelRect.left || x > panelRect.right || y < panelRect.top || y > panelRect.bottom;
}

function snapRootLaunchPosition(
  position: LaunchPosition,
  dockGridSettings: DockGridSettings,
): LaunchPosition {
  const coordinates = getRootLaunchGridCoordinates(position, dockGridSettings);

  return getRootLaunchPositionFromGrid(coordinates.column, coordinates.row, dockGridSettings);
}

function getRootLaunchItemPosition(
  item: LaunchItem,
  index: number,
  dockGridSettings: DockGridSettings,
): LaunchPosition {
  return item.position
    ? snapRootLaunchPosition(item.position, dockGridSettings)
    : getFallbackRootLaunchPosition(index, dockGridSettings);
}

function getOccupiedRootLaunchPositionKeys(
  items: LaunchItem[],
  dockGridSettings: DockGridSettings,
  excludedItemId?: string,
): Set<string> {
  const occupiedPositions = new Set<string>();

  items
    .filter((item) => getLaunchGroupKey(item.group) === rootLaunchGroup)
    .sort(sortLaunchItems)
    .forEach((item, index) => {
      if (item.id === excludedItemId) {
        return;
      }

      occupiedPositions.add(
        getRootLaunchPositionKey(
          getRootLaunchItemPosition(item, index, dockGridSettings),
          dockGridSettings,
        ),
      );
    });

  return occupiedPositions;
}

function getRootDirectoryItemPosition(
  item: DirectoryItem,
  index: number,
  dockGridSettings: DockGridSettings,
): LaunchPosition {
  return item.position
    ? snapRootLaunchPosition(item.position, dockGridSettings)
    : getFallbackRootLaunchPosition(index, dockGridSettings);
}

function getOccupiedRootDirectoryPositionKeys(
  items: DirectoryItem[],
  dockGridSettings: DockGridSettings,
  excludedItemId?: string,
): Set<string> {
  const occupiedPositions = new Set<string>();

  [...items].sort(sortDirectoryItems).forEach((item, index) => {
    if (item.id === excludedItemId) {
      return;
    }

    occupiedPositions.add(
      getRootLaunchPositionKey(
        getRootDirectoryItemPosition(item, index, dockGridSettings),
        dockGridSettings,
      ),
    );
  });

  return occupiedPositions;
}

function getRootLaunchPositionFromClient(
  x: number,
  y: number,
  rootElement: HTMLElement | null,
  dockGridSettings: DockGridSettings,
  scale = 1,
): LaunchPosition {
  const safeScale = Math.max(scale, 0.01);

  if (!rootElement) {
    return snapRootLaunchPosition({
      x: Math.max(x / safeScale - launchGroupMetrics.cellWidth / 2, 0),
      y: Math.max(y / safeScale - launchGroupMetrics.cellHeight / 2, 0),
    }, dockGridSettings);
  }

  const rootRect = rootElement.getBoundingClientRect();

  return snapRootLaunchPosition({
    x: Math.max((x - rootRect.left) / safeScale - launchGroupMetrics.cellWidth / 2, 0),
    y: Math.max((y - rootRect.top) / safeScale - launchGroupMetrics.cellHeight / 2, 0),
  }, dockGridSettings);
}

function getLaunchDropShadowPosition(
  x: number,
  y: number,
  rootElement: HTMLElement | null,
  dockGridSettings: DockGridSettings,
  scale = 1,
): { x: number; y: number } {
  const safeScale = Math.max(scale, 0.01);
  const rootPosition = getRootLaunchPositionFromClient(
    x,
    y,
    rootElement,
    dockGridSettings,
    safeScale,
  );
  const rootRect = rootElement?.getBoundingClientRect();

  return {
    x: (rootRect?.left ?? 0) + (rootPosition.x + launchGroupMetrics.cellWidth / 2) * safeScale,
    y: (rootRect?.top ?? 0) + (rootPosition.y + launchGroupMetrics.cellHeight / 2) * safeScale,
  };
}

function getLaunchDragPreviewPosition(
  session: Pick<LaunchDragSession, "previewStartX" | "previewStartY" | "startX" | "startY">,
  x: number,
  y: number,
): { x: number; y: number } {
  return {
    x: session.previewStartX + x - session.startX,
    y: session.previewStartY + y - session.startY,
  };
}

function getLaunchGroupRect(layout: LaunchGroupLayout): LaunchRect {
  return createLaunchRectFromPosition(layout.position ?? { x: 0, y: 0 }, layout.width, layout.height);
}

function getLaunchGroupBaseLayout(
  group: LaunchGroupDescriptor,
  layouts: Record<string, LaunchGroupLayout>,
): LaunchGroupLayout {
  const storedLayout = layouts[group.name];

  if (!storedLayout) {
    return getAutoGroupLayout(group.itemCount);
  }

  const normalizedLayout = normalizeGroupLayout(storedLayout);
  const autoLayout = normalizedLayout.manualSize
    ? normalizedLayout
    : getGroupLayoutForColumns(
        group.itemCount,
        getTrackCountFromSize(
          normalizedLayout.width,
          launchGroupMetrics.cellWidth,
          launchGroupMetrics.gapX,
          launchGroupMetrics.minColumns,
          launchGroupMetrics.maxColumns,
          getAutoGroupLayout(group.itemCount).columns,
        ),
      );

  return {
    ...autoLayout,
    iconSize: normalizedLayout.iconSize,
    manualPosition: normalizedLayout.manualPosition,
    manualSize: normalizedLayout.manualSize,
    position: normalizedLayout.manualPosition ? normalizedLayout.position : undefined,
  };
}

function getPlacementCandidateOrder(
  first: LaunchGroupPlacementCandidate,
  second: LaunchGroupPlacementCandidate,
): number {
  const firstPosition = first.layout.position;
  const secondPosition = second.layout.position;

  if (firstPosition && secondPosition) {
    return firstPosition.y - secondPosition.y || firstPosition.x - secondPosition.x || first.index - second.index;
  }

  if (firstPosition || secondPosition) {
    return firstPosition ? -1 : 1;
  }

  return first.index - second.index;
}

function createLaunchGroupFlowCursor(rootFlowWidth: number): LaunchGroupFlowCursor {
  return {
    rowHeight: 0,
    x: rootFlowWidth,
    y: 0,
  };
}

function getNextAutoLaunchGroupPosition(
  layout: LaunchGroupLayout,
  cursor: LaunchGroupFlowCursor,
  rootFlowWidth: number,
  containerWidth: number,
): LaunchPosition {
  const availableWidth = containerWidth > 0 ? Math.max(containerWidth - rootFlowWidth, 0) : 0;

  if (
    cursor.x > rootFlowWidth &&
    availableWidth > 0 &&
    layout.width <= availableWidth &&
    cursor.x + layout.width > containerWidth
  ) {
    cursor.x = rootFlowWidth;
    cursor.y += cursor.rowHeight + launchGroupGap;
    cursor.rowHeight = 0;
  }

  const position = {
    x: cursor.x,
    y: cursor.y,
  };

  cursor.x += layout.width + launchGroupGap;
  cursor.rowHeight = Math.max(cursor.rowHeight, layout.height);

  return position;
}

function clampLaunchGroupPosition(
  position: LaunchPosition,
  width: number,
  height: number,
  rootFlowWidth: number,
  _containerWidth: number,
  dockGridSettings: DockGridSettings,
): LaunchPosition {
  const columnStep = getLaunchColumnStep();
  const rowStep = getLaunchRowStep();
  const columnSpan = getTrackCountFromSize(
    width,
    launchGroupMetrics.cellWidth,
    launchGroupMetrics.gapX,
    1,
    dockGridSettings.columns,
    1,
  );
  const rowSpan = getTrackCountFromSize(
    height,
    launchGroupMetrics.cellHeight,
    launchGroupMetrics.gapY,
    1,
    dockGridSettings.rows,
    1,
  );
  const maxColumn = Math.max(dockGridSettings.columns - columnSpan, 0);
  const maxRow = Math.max(dockGridSettings.rows - rowSpan, 0);
  const column = clampInteger(
    (position.x - launchGroupMetrics.padding) / columnStep,
    rootFlowWidth > 0 ? Math.ceil(rootFlowWidth / columnStep) : 0,
    maxColumn,
  );
  const row = clampInteger(
    (position.y - launchGroupMetrics.padding) / rowStep,
    0,
    maxRow,
  );

  return getRootLaunchPositionFromGrid(column, row, dockGridSettings);
}

function doLaunchRectsIntersect(first: LaunchRect, second: LaunchRect, gap = 0): boolean {
  return (
    first.left < second.right + gap &&
    first.right + gap > second.left &&
    first.top < second.bottom + gap &&
    first.bottom + gap > second.top
  );
}

function isLaunchGroupPositionAvailable(
  position: LaunchPosition,
  width: number,
  height: number,
  unavailableRects: LaunchRect[],
  rootFlowWidth: number,
  containerWidth: number,
  dockGridSettings: DockGridSettings,
  _enforceRowSeparation = false,
): boolean {
  const rect = createLaunchRectFromPosition(position, width, height);
  const availableWidth = containerWidth > 0 ? Math.max(containerWidth - rootFlowWidth, 0) : 0;

  if (position.x < rootFlowWidth || position.y < 0) {
    return false;
  }

  if (
    rect.right > getRootLaunchGridWidth(dockGridSettings) ||
    rect.bottom > getRootLaunchGridHeight(dockGridSettings)
  ) {
    return false;
  }

  if (availableWidth > 0 && width <= availableWidth && rect.right > containerWidth) {
    return false;
  }

  return unavailableRects.every((otherRect) => !doLaunchRectsIntersect(rect, otherRect));
}

function getNearestAvailableLaunchGroupPosition(
  preferredPosition: LaunchPosition,
  width: number,
  height: number,
  unavailableRects: LaunchRect[],
  rootFlowWidth: number,
  containerWidth: number,
  dockGridSettings: DockGridSettings,
  enforceRowSeparation = false,
): LaunchPosition {
  const origin = clampLaunchGroupPosition(
    preferredPosition,
    width,
    height,
    rootFlowWidth,
    containerWidth,
    dockGridSettings,
  );
  const columnStep = getLaunchColumnStep();
  const rowStep = getLaunchRowStep();
  const checkedPositions = new Set<string>();
  const rowAnchors = [
    origin.y,
    ...unavailableRects.flatMap((rect) => [rect.top, rect.bottom + launchGroupGap]),
  ].filter((value, index, values) => values.indexOf(value) === index);
  const columnAnchors = [
    origin.x,
    ...unavailableRects.flatMap((rect) => [
      rect.left,
      rect.right + launchGroupGap,
      rect.left - width - launchGroupGap,
    ]),
  ].filter((value, index, values) => values.indexOf(value) === index);

  for (let radius = 0; radius <= launchGroupPlacementSearchRadius; radius += 1) {
    const candidates: LaunchPosition[] = [];

    for (let rowDelta = -radius; rowDelta <= radius; rowDelta += 1) {
      for (let columnDelta = -radius; columnDelta <= radius; columnDelta += 1) {
        if (Math.max(Math.abs(rowDelta), Math.abs(columnDelta)) !== radius) {
          continue;
        }

        candidates.push(
          clampLaunchGroupPosition(
            {
              x: origin.x + columnDelta * columnStep,
              y: origin.y + rowDelta * rowStep,
            },
            width,
            height,
            rootFlowWidth,
            containerWidth,
            dockGridSettings,
          ),
        );
      }
    }

    rowAnchors.forEach((rowAnchor) => {
      const rowDistance = Math.ceil(Math.abs(rowAnchor - origin.y) / rowStep);

      if (rowDistance > radius) {
        return;
      }

      columnAnchors.forEach((columnAnchor) => {
        const columnDistance = Math.ceil(Math.abs(columnAnchor - origin.x) / columnStep);

        if (columnDistance > radius) {
          return;
        }

        candidates.push(
          clampLaunchGroupPosition(
            {
              x: columnAnchor,
              y: rowAnchor,
            },
            width,
            height,
            rootFlowWidth,
            containerWidth,
            dockGridSettings,
          ),
        );
      });
    });

    candidates.sort((first, second) => {
      const firstDistance = Math.hypot(first.x - origin.x, first.y - origin.y);
      const secondDistance = Math.hypot(second.x - origin.x, second.y - origin.y);

      return firstDistance - secondDistance || first.y - second.y || first.x - second.x;
    });

    for (const candidate of candidates) {
      const key = `${Math.round(candidate.x)}:${Math.round(candidate.y)}`;

      if (checkedPositions.has(key)) {
        continue;
      }

      checkedPositions.add(key);

      if (
        isLaunchGroupPositionAvailable(
          candidate,
          width,
          height,
          unavailableRects,
          rootFlowWidth,
          containerWidth,
          dockGridSettings,
          enforceRowSeparation,
        )
      ) {
        return candidate;
      }
    }
  }

  return clampLaunchGroupPosition(
    {
      x: rootFlowWidth,
      y:
        unavailableRects.reduce(
          (bottomEdge, rect) => Math.max(bottomEdge, rect.bottom),
          0,
        ) + launchGroupGap,
    },
    width,
    height,
    rootFlowWidth,
    containerWidth,
    dockGridSettings,
  );
}

function resolveLaunchGroupLayouts(
  groups: LaunchGroupDescriptor[],
  layouts: Record<string, LaunchGroupLayout>,
  rootFlowWidth: number,
  containerWidth: number,
  dockGridSettings: DockGridSettings,
  unavailableRects: LaunchRect[] = [],
): Record<string, LaunchGroupLayout> {
  const resolvedLayouts: Record<string, LaunchGroupLayout> = {};
  const placedRects: LaunchRect[] = [...unavailableRects];
  const autoFlowCursor = createLaunchGroupFlowCursor(rootFlowWidth);
  const candidates = groups
    .map<LaunchGroupPlacementCandidate>((group, index) => ({
      descriptor: group,
      index,
      layout: getLaunchGroupBaseLayout(group, layouts),
    }))
    .sort(getPlacementCandidateOrder);

  candidates.forEach((candidate) => {
    const preferredPosition =
      candidate.layout.manualPosition && candidate.layout.position
        ? candidate.layout.position
        : getNextAutoLaunchGroupPosition(
            candidate.layout,
            autoFlowCursor,
            rootFlowWidth,
            containerWidth,
          );
    const position = getNearestAvailableLaunchGroupPosition(
      preferredPosition,
      candidate.layout.width,
      candidate.layout.height,
      placedRects,
      rootFlowWidth,
      containerWidth,
      dockGridSettings,
      !candidate.layout.manualPosition,
    );
    const resolvedLayout = normalizeGroupLayout({
      ...candidate.layout,
      position,
    });

    resolvedLayouts[candidate.descriptor.name] = resolvedLayout;
    placedRects.push(getLaunchGroupRect(resolvedLayout));
  });

  return resolvedLayouts;
}

function getRootLaunchEntryCount(items: LaunchItem[]): number {
  const groupKeys = new Set<string>();
  let rootItemCount = 0;

  items.forEach((item) => {
    const groupKey = getLaunchGroupKey(item.group);

    if (groupKey === rootLaunchGroup) {
      rootItemCount += 1;
      return;
    }

    groupKeys.add(groupKey);
  });

  return rootItemCount + groupKeys.size;
}

function expandDockGridSettingsToFitItems(
  dockGridSettings: DockGridSettings,
  itemCount: number,
): DockGridSettings {
  if (getRootLaunchGridCapacity(dockGridSettings) >= itemCount) {
    return dockGridSettings;
  }

  const rowsForCurrentColumns = clampInteger(
    Math.ceil(itemCount / dockGridSettings.columns),
    dockGridRowRange.min,
    dockGridRowRange.max,
  );

  if (dockGridSettings.columns * rowsForCurrentColumns >= itemCount) {
    return {
      ...dockGridSettings,
      rows: rowsForCurrentColumns,
    };
  }

  return normalizeDockGridSettings({
    columns: Math.ceil(itemCount / dockGridRowRange.max),
    rows: dockGridRowRange.max,
  });
}

function getInitialLaunchState(): InitialLaunchState {
  const storedDockGridSettings = getStoredDockGridSettings();
  const storedLaunchItems = getStoredLaunchItems();
  const storedDirectoryItems = getStoredDirectoryItems();
  const requiredRootEntryCount = Math.max(
    getRootLaunchEntryCount(storedLaunchItems),
    storedDirectoryItems.length,
  );
  const dockGridSettings = expandDockGridSettingsToFitItems(
    storedDockGridSettings,
    requiredRootEntryCount,
  );

  return {
    dockGridSettings,
    directoryItems: normalizeRootDirectoryPositions(storedDirectoryItems, dockGridSettings),
    launchItems: normalizeRootLaunchPositions(storedLaunchItems, dockGridSettings),
  };
}

function FloatingBallVisual({
  floatingBallStyle,
  isPreview = false,
  metricsHistory,
}: {
  floatingBallStyle: FloatingBallStyle;
  isPreview?: boolean;
  metricsHistory: SystemMetrics[];
}) {
  switch (floatingBallStyle) {
    case "networkSpeed":
      return (
        <FloatingBallNetworkVisual
          isPreview={isPreview}
          metricsHistory={metricsHistory}
        />
      );
    case "systemPressure":
      return (
        <FloatingBallSystemVisual
          isPreview={isPreview}
          metricsHistory={metricsHistory}
        />
      );
    case "rotatingGlobe":
      return (
        <img
          className="floating-ball-avatar"
          src={floatingBallAvatarUrl}
          alt=""
          draggable={false}
        />
      );
  }
}

function FloatingBallNetworkVisual({
  isPreview = false,
  metricsHistory,
}: {
  isPreview?: boolean;
  metricsHistory: SystemMetrics[];
}) {
  const displayHistory = metricsHistory.length > 1 ? metricsHistory : previewMetricsHistory;
  const currentMetrics = getLatestSystemMetrics(displayHistory);
  const downloadValues = displayHistory.map((metrics) => metrics.downloadBytesPerSecond);
  const uploadValues = displayHistory.map((metrics) => metrics.uploadBytesPerSecond);
  const chartScaleMax = Math.max(...downloadValues, ...uploadValues, 1);
  const totalSpeed = currentMetrics.downloadBytesPerSecond + currentMetrics.uploadBytesPerSecond;
  const downloadSpeed = getBytesPerSecondDisplay(currentMetrics.downloadBytesPerSecond);
  const uploadSpeed = getBytesPerSecondDisplay(currentMetrics.uploadBytesPerSecond);
  const peakSpeed = Math.max(
    ...displayHistory.map(
      (metrics) => metrics.downloadBytesPerSecond + metrics.uploadBytesPerSecond,
    ),
    1,
  );
  const networkLoad = clampNumber(totalSpeed / peakSpeed, 0.12, 1, 0.12);
  const networkGlowOpacity = 0.16 + networkLoad * 0.28;
  const networkPulseOpacity = 0.32 + networkLoad * 0.34;

  return (
    <span
      className={[
        "floating-ball-meter",
        "floating-ball-network",
        isPreview ? "preview" : "",
      ]
        .filter(Boolean)
        .join(" ")}
      style={
        {
          "--network-glow-opacity": networkGlowOpacity,
          "--network-load": networkLoad,
          "--network-pulse-opacity": networkPulseOpacity,
        } as CSSProperties
      }
    >
      <span className="network-pulse" />
      <svg
        className="network-history-chart"
        viewBox="0 0 56 56"
        aria-hidden="true"
        focusable="false"
      >
        <line className="network-axis edge" x1="0" y1="8" x2="56" y2="8" />
        <line className="network-axis middle" x1="0" y1="28" x2="56" y2="28" />
        <line className="network-axis edge" x1="0" y1="48" x2="56" y2="48" />
        <polygon
          className="network-history-fill download"
          points={getDirectionalSparklineAreaPoints(downloadValues, 56, 28, 19, "up", chartScaleMax)}
        />
        <polygon
          className="network-history-fill upload"
          points={getDirectionalSparklineAreaPoints(uploadValues, 56, 28, 19, "down", chartScaleMax)}
        />
        <polyline
          className="network-history-line download"
          points={getDirectionalSparklinePoints(downloadValues, 56, 28, 19, "up", chartScaleMax)}
        />
        <polyline
          className="network-history-line upload"
          points={getDirectionalSparklinePoints(uploadValues, 56, 28, 19, "down", chartScaleMax)}
        />
      </svg>
      <span className="network-speed-stack">
        <span className="network-speed-row download">
          <NetworkDirectionIcon direction="down" />
          <span className="network-speed-value">{downloadSpeed.value}</span>
          <span className="network-speed-unit">{downloadSpeed.unit}</span>
        </span>
        <span className="network-speed-row upload">
          <NetworkDirectionIcon direction="up" />
          <span className="network-speed-value">{uploadSpeed.value}</span>
          <span className="network-speed-unit">{uploadSpeed.unit}</span>
        </span>
      </span>
    </span>
  );
}

function NetworkDirectionIcon({ direction }: { direction: "down" | "up" }) {
  const path =
    direction === "down"
      ? "M6 1.5v7M2.9 5.7 6 8.8l3.1-3.1"
      : "M6 10.5v-7M2.9 6.3 6 3.2l3.1 3.1";
  const textArrow = direction === "down" ? "↓" : "↑";

  return (
    <span className="network-speed-direction" aria-hidden="true">
      <span className="network-speed-direction-text">{textArrow}</span>
      <svg viewBox="0 0 12 12" focusable="false">
        <path d={path} />
      </svg>
    </span>
  );
}

function FloatingBallSystemVisual({
  isPreview = false,
  metricsHistory,
}: {
  isPreview?: boolean;
  metricsHistory: SystemMetrics[];
}) {
  const displayHistory = metricsHistory.length > 0 ? metricsHistory : previewMetricsHistory;
  const currentMetrics = getLatestSystemMetrics(displayHistory);
  const cpuUsage = clampNumber(currentMetrics.cpuUsage, 0, 100, 0);
  const memoryUsage = clampNumber(currentMetrics.memoryUsage, 0, 100, 0);
  const pressure = Math.max(cpuUsage, memoryUsage);

  return (
    <span
      className={[
        "floating-ball-meter",
        "floating-ball-system",
        isPreview ? "preview" : "",
      ]
        .filter(Boolean)
        .join(" ")}
      style={
        {
          "--cpu-bar-width": `${cpuUsage}%`,
          "--cpu-usage": cpuUsage,
          "--memory-bar-width": `${memoryUsage}%`,
          "--memory-usage": memoryUsage,
          "--pressure": pressure,
        } as CSSProperties
      }
    >
      <svg
        className="system-pressure-rings"
        viewBox="0 0 64 64"
        aria-hidden="true"
        focusable="false"
      >
        <circle className="system-ring-track outer" cx="32" cy="32" r="25" />
        <circle className="system-ring-track inner" cx="32" cy="32" r="19" />
        <circle className="system-ring cpu" cx="32" cy="32" r="25" pathLength="100" />
        <circle className="system-ring memory" cx="32" cy="32" r="19" pathLength="100" />
      </svg>
      <span className="system-pressure-center">
        <span>{Math.round(pressure)}</span>
        <span>%</span>
      </span>
      <span className="system-pressure-bars" aria-hidden="true">
        <span className="cpu" />
        <span className="memory" />
      </span>
    </span>
  );
}

function FloatingBallApp() {
  const currentWindowRef = useRef(getCurrentWindow());
  const suppressClickRef = useRef(false);
  const [isActivating, setIsActivating] = useState(false);
  const [floatingBallStyle, setFloatingBallStyle] = useState<FloatingBallStyle>(
    getStoredFloatingBallStyle,
  );
  const [metricsHistory, setMetricsHistory] = useState<SystemMetrics[]>([]);

  useEffect(() => {
    document.documentElement.lang = "zh-CN";
  }, []);

  useEffect(() => {
    const handleStorage = (event: StorageEvent) => {
      if (event.key !== floatingBallStyleStorageKey) {
        return;
      }

      setFloatingBallStyle(
        isFloatingBallStyle(event.newValue) ? event.newValue : defaultFloatingBallStyle,
      );
    };

    window.addEventListener("storage", handleStorage);

    return () => window.removeEventListener("storage", handleStorage);
  }, []);

  useEffect(() => {
    if (!isMetricFloatingBallStyle(floatingBallStyle)) {
      return;
    }

    let isCancelled = false;

    const updateMetrics = async () => {
      try {
        const nextMetrics = normalizeSystemMetrics(await invoke("system_metrics"));

        if (isCancelled) {
          return;
        }

        setMetricsHistory((history) => [
          ...history.slice(-(floatingBallMetricsHistoryLimit - 1)),
          nextMetrics,
        ]);
      } catch {
        return;
      }
    };

    void updateMetrics();
    const intervalId = window.setInterval(updateMetrics, floatingBallMetricsRefreshMs);

    return () => {
      isCancelled = true;
      window.clearInterval(intervalId);
    };
  }, [floatingBallStyle]);

  function handlePointerDown(event: ReactPointerEvent<HTMLButtonElement>) {
    if (event.button !== 0) {
      return;
    }

    const startX = event.screenX;
    const startY = event.screenY;
    suppressClickRef.current = false;

    const cleanup = () => {
      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("pointerup", cleanup);
      window.removeEventListener("pointercancel", cleanup);
    };

    const handlePointerMove = (moveEvent: PointerEvent) => {
      if (
        Math.hypot(moveEvent.screenX - startX, moveEvent.screenY - startY) <
        floatingBallDragThreshold
      ) {
        return;
      }

      suppressClickRef.current = true;
      cleanup();
      void currentWindowRef.current.startDragging().catch(() => undefined);
    };

    window.addEventListener("pointermove", handlePointerMove);
    window.addEventListener("pointerup", cleanup);
    window.addEventListener("pointercancel", cleanup);
  }

  async function handleActivateMainWindow() {
    if (suppressClickRef.current) {
      suppressClickRef.current = false;
      return;
    }

    setIsActivating(true);

    try {
      await invoke("activate_main_window");
    } catch {
      return;
    } finally {
      window.setTimeout(() => setIsActivating(false), 180);
    }
  }

  return (
    <main className="floating-ball-shell">
      <button
        className={["floating-ball-trigger", isActivating ? "activating" : ""]
          .filter(Boolean)
          .join(" ")}
        type="button"
        title="显示方寸 InchSpace"
        aria-label="显示方寸 InchSpace"
        onPointerDown={handlePointerDown}
        onClick={() => void handleActivateMainWindow()}
      >
        <FloatingBallVisual
          floatingBallStyle={floatingBallStyle}
          metricsHistory={metricsHistory}
        />
      </button>
    </main>
  );
}

function MainApp() {
  const [initialLaunchState] = useState<InitialLaunchState>(getInitialLaunchState);
  const [activeMenu, setActiveMenu] = useState<MenuId>("dock");
  const [activeDockTab, setActiveDockTab] = useState<DockContentTabId>("programs");
  const [systemLanguage, setSystemLanguage] = useState<AppLanguage>(getSystemLanguage);
  const [languagePreference, setLanguagePreference] =
    useState<LanguagePreference>(getStoredLanguagePreference);
  const [floatingBallStyle, setFloatingBallStyle] = useState<FloatingBallStyle>(
    getStoredFloatingBallStyle,
  );
  const [dockIconVisible, setDockIconVisible] = useState(getStoredDockIconVisible);
  const [dockGridSettings, setDockGridSettings] = useState<DockGridSettings>(
    initialLaunchState.dockGridSettings,
  );
  const [launchItems, setLaunchItems] = useState<LaunchItem[]>(initialLaunchState.launchItems);
  const [directoryItems, setDirectoryItems] =
    useState<DirectoryItem[]>(initialLaunchState.directoryItems);
  const [launchGroupLayouts, setLaunchGroupLayouts] =
    useState<Record<string, LaunchGroupLayout>>(getStoredGroupLayouts);
  const [launchGroupNames, setLaunchGroupNames] =
    useState<Record<string, string>>(getStoredLaunchGroupNames);
  const [launchGroupPages, setLaunchGroupPages] = useState<Record<string, number>>({});
  const [launchGroupSwipeState, setLaunchGroupSwipeState] =
    useState<LaunchGroupSwipeState | null>(null);
  const [launchError, setLaunchError] = useState<string | null>(null);
  const [dockGridSettingsError, setDockGridSettingsError] = useState<string | null>(null);
  const [isForceShutdownPending, setIsForceShutdownPending] = useState(false);
  const [editingLaunchGroupName, setEditingLaunchGroupName] = useState<string | null>(null);
  const [launchGroupNameDraft, setLaunchGroupNameDraft] = useState("");
  const [openLaunchGroupName, setOpenLaunchGroupName] = useState<string | null>(null);
  const [launchDragState, setLaunchDragState] = useState<LaunchDragState | null>(null);
  const [launchGroupDragState, setLaunchGroupDragState] =
    useState<LaunchGroupDragState | null>(null);
  const [directoryDragState, setDirectoryDragState] = useState<DirectoryDragState | null>(null);
  const [isLaunchEditMode, setIsLaunchEditMode] = useState(false);
  const launchEditModeRef = useRef(false);
  const launchDragSessionRef = useRef<LaunchDragSession | null>(null);
  const launchGroupDragSessionRef = useRef<LaunchGroupDragSession | null>(null);
  const directoryDragSessionRef = useRef<DirectoryDragSession | null>(null);
  const dockViewRef = useRef<HTMLDivElement | null>(null);
  const launchGroupSwipeSessionRef = useRef<LaunchGroupSwipeSession | null>(null);
  const launchLongPressTimerRef = useRef<number | null>(null);
  const launchGroupWheelTurnRef = useRef<Record<string, LaunchGroupWheelState>>({});
  const launchGroupsRef = useRef<HTMLDivElement | null>(null);
  const launchGroupNameInputRef = useRef<HTMLInputElement | null>(null);
  const launchRootRef = useRef<HTMLDivElement | null>(null);
  const launchIconRefreshAttemptedPathsRef = useRef<Set<string>>(new Set());
  const directoryIconRefreshAttemptedPathsRef = useRef<Set<string>>(new Set());
  const suppressLaunchItemIdRef = useRef<string | null>(null);
  const suppressLaunchGroupNameRef = useRef<string | null>(null);
  const suppressDirectoryItemIdRef = useRef<string | null>(null);
  const [launchGroupsWidth, setLaunchGroupsWidth] = useState(() =>
    getRootLaunchGridWidth(dockGridSettings),
  );
  const [dockViewSize, setDockViewSize] = useState(() => ({
    height: getRootLaunchGridHeight(dockGridSettings),
    width: getRootLaunchGridWidth(dockGridSettings),
  }));
  const appLanguage = languagePreference === "system" ? systemLanguage : languagePreference;
  const localizedCopy = copy[appLanguage];
  const sortedDirectoryItems = useMemo(
    () => [...directoryItems].sort(sortDirectoryItems),
    [directoryItems],
  );
  const { launchGroups, rootLaunchItems } = useMemo(() => {
    const groups = new Map<string, LaunchItem[]>();
    const rootItems: LaunchItem[] = [];

    launchItems.forEach((item) => {
      const group = getLaunchGroupKey(item.group);

      if (group === rootLaunchGroup) {
        rootItems.push(item);
        return;
      }

      groups.set(group, [...(groups.get(group) ?? []), item]);
    });

    return {
      launchGroups: [...groups.entries()].map<LaunchGroupView>(([name, items], index) => ({
        displayName: getLaunchGroupDisplayName(name, index),
        items: [...items].sort(sortLaunchItems),
        name,
      })),
      rootLaunchItems: rootItems.sort(sortLaunchItems),
    };
  }, [launchGroupNames, launchItems, localizedCopy.group]);
  const draggedLaunchItem = launchDragState
    ? launchItems.find((item) => item.id === launchDragState.itemId)
    : undefined;
  const draggedDirectoryItem = directoryDragState
    ? directoryItems.find((item) => item.id === directoryDragState.itemId)
    : undefined;
  const draggedLaunchGroup = launchGroupDragState
    ? launchGroups.find((group) => group.name === launchGroupDragState.groupName)
    : undefined;
  const openLaunchGroup = openLaunchGroupName
    ? launchGroups.find((group) => group.name === openLaunchGroupName)
    : undefined;
  const openLaunchGroupPreviewItems = openLaunchGroup
    ? getPreviewGroupItems(openLaunchGroup.name, openLaunchGroup.items)
    : [];
  const openLaunchGroupBaseLayout = openLaunchGroup
    ? getOpenLaunchGroupBaseLayout(openLaunchGroupPreviewItems.length)
    : null;
  const launchGroupsCanvasWidth = getRootLaunchGridWidth(dockGridSettings);
  const launchGroupsCanvasHeight = getRootLaunchGridHeight(dockGridSettings);
  const openLaunchGroupLayout = openLaunchGroup ? openLaunchGroupBaseLayout : null;
  const rootLaunchFlowWidth = useMemo(
    () => getLaunchRootFlowWidth(),
    [],
  );
  const rootLaunchEntries = useMemo<LaunchRootEntry[]>(
    () => [
      ...rootLaunchItems.map((item) => ({
        id: item.id,
        item,
        kind: "item" as const,
      })),
      ...launchGroups.map((group) => ({
        group,
        id: group.name,
        kind: "group" as const,
      })),
    ],
    [launchGroups, rootLaunchItems],
  );
  const previewRootLaunchEntries = useMemo<LaunchRootEntry[]>(() => {
    const targetGroup = launchDragState?.targetGroup
      ? getLaunchGroupKey(launchDragState.targetGroup)
      : null;

    if (
      !launchDragState ||
      !draggedLaunchItem ||
      targetGroup !== rootLaunchGroup ||
      launchDragState.targetAction !== "insert" ||
      launchDragState.rootDropAction === "position"
    ) {
      return rootLaunchEntries;
    }

    const target: LaunchRootInsertionTarget | null = launchDragState.targetId
      ? {
          entryId: launchDragState.targetId,
          insertAfter: launchDragState.insertAfterTarget,
          kind: "entry",
        }
      : launchDragState.rootInsertIndex !== null
        ? {
            index: launchDragState.rootInsertIndex,
            kind: "index",
          }
        : null;

    return target
      ? getRootEntriesWithInsertedItem(
          rootLaunchEntries,
          draggedLaunchItem,
          target,
          dockGridSettings,
          launchGroupLayouts,
        ) ?? rootLaunchEntries
      : rootLaunchEntries;
  }, [
    dockGridSettings,
    draggedLaunchItem,
    launchDragState,
    launchGroupLayouts,
    rootLaunchEntries,
  ]);
  const resolvedRootEntryPositions = useMemo<ResolvedRootEntryPositions>(() => {
    if (previewRootLaunchEntries !== rootLaunchEntries) {
      return getRootEntryPositionsFromOrder(previewRootLaunchEntries, dockGridSettings);
    }

    const occupiedPositions = new Set<string>();
    const items = new Map<string, LaunchPosition>();
    const groups = new Map<string, LaunchPosition>();

    rootLaunchEntries.forEach((entry, index) => {
      const preferredPosition =
        entry.kind === "item"
          ? entry.item.position
          : launchGroupLayouts[entry.group.name]?.position;
      const position = getNearestAvailableRootLaunchPosition(
        occupiedPositions,
        preferredPosition ?? getFallbackRootLaunchPosition(index, dockGridSettings),
        dockGridSettings,
      );

      if (!position) {
        return;
      }

      occupiedPositions.add(getRootLaunchPositionKey(position, dockGridSettings));

      if (entry.kind === "item") {
        items.set(entry.item.id, position);
      } else {
        groups.set(entry.group.name, position);
      }
    });

    return {
      groups,
      items,
    };
  }, [dockGridSettings, launchGroupLayouts, previewRootLaunchEntries, rootLaunchEntries]);
  const resolvedDirectoryPositions = useMemo(() => {
    const occupiedPositions = new Set<string>();
    const positions = new Map<string, LaunchPosition>();

    sortedDirectoryItems.forEach((item, index) => {
      const position = getNearestAvailableRootLaunchPosition(
        occupiedPositions,
        item.position ?? getFallbackRootLaunchPosition(index, dockGridSettings),
        dockGridSettings,
      );

      if (!position) {
        return;
      }

      occupiedPositions.add(getRootLaunchPositionKey(position, dockGridSettings));
      positions.set(item.id, position);
    });

    return positions;
  }, [dockGridSettings, sortedDirectoryItems]);
  const rootLaunchEntryRects = useMemo(
    () =>
      previewRootLaunchEntries.flatMap((entry) => {
        const position =
          entry.kind === "item"
            ? resolvedRootEntryPositions.items.get(entry.item.id)
            : resolvedRootEntryPositions.groups.get(entry.group.name);

        return position
          ? [createLaunchRectFromPosition(position, launchGroupMetrics.cellWidth, launchGroupMetrics.cellHeight)]
          : [];
      }),
    [previewRootLaunchEntries, resolvedRootEntryPositions],
  );
  const previewLaunchGroupDescriptors = useMemo(
    () =>
      launchGroups.map((group) => ({
        itemCount: getPreviewGroupItems(group.name, group.items).length,
        name: group.name,
      })),
    [draggedLaunchItem, launchDragState, launchGroups],
  );
  const resolvedLaunchGroupLayouts = useMemo(
    () =>
      resolveLaunchGroupLayouts(
        previewLaunchGroupDescriptors,
        launchGroupLayouts,
        rootLaunchFlowWidth,
        launchGroupsWidth,
        dockGridSettings,
        rootLaunchEntryRects,
      ),
    [
      dockGridSettings,
      launchGroupLayouts,
      launchGroupsWidth,
      previewLaunchGroupDescriptors,
      rootLaunchFlowWidth,
      rootLaunchEntryRects,
    ],
  );
  const launchGroupsScale = clampNumber(
    Math.min(
      1,
      dockViewSize.width / Math.max(launchGroupsCanvasWidth, 1),
      dockViewSize.height / Math.max(launchGroupsCanvasHeight, 1),
    ),
    0.35,
    1,
    1,
  );

  function getLaunchGroupDisplayName(groupName: string, groupIndex: number): string {
    return launchGroupNames[groupName]?.trim() || `${localizedCopy.group} ${groupIndex + 1}`;
  }

  function beginEditingLaunchGroupName(groupName: string, displayName: string) {
    clearLaunchLongPressTimer();
    setEditingLaunchGroupName(groupName);
    setLaunchGroupNameDraft(displayName);
  }

  function cancelEditingLaunchGroupName() {
    setEditingLaunchGroupName(null);
    setLaunchGroupNameDraft("");
  }

  function commitEditingLaunchGroupName() {
    if (!editingLaunchGroupName) {
      return;
    }

    const groupName = editingLaunchGroupName;
    const nextDisplayName = launchGroupNameDraft.trim().slice(0, 48);

    setLaunchGroupNames((names) => {
      const nextNames = { ...names };

      if (nextDisplayName) {
        nextNames[groupName] = nextDisplayName;
      } else {
        delete nextNames[groupName];
      }

      return nextNames;
    });
    cancelEditingLaunchGroupName();
  }

  function setLaunchEditMode(isEditing: boolean) {
    launchEditModeRef.current = isEditing;
    setIsLaunchEditMode(isEditing);
  }

  function getRootLaunchPosition(item: LaunchItem, index: number): LaunchPosition {
    return (
      resolvedRootEntryPositions.items.get(item.id) ??
      getRootLaunchItemPosition(item, index, dockGridSettings)
    );
  }

  function getRootLaunchAppStyle(item: LaunchItem, index: number): CSSProperties {
    const position = getRootLaunchPosition(item, index);

    return {
      left: `${position.x}px`,
      top: `${position.y}px`,
    };
  }

  function getRootDirectoryPosition(item: DirectoryItem, index: number): LaunchPosition {
    return (
      resolvedDirectoryPositions.get(item.id) ??
      getRootDirectoryItemPosition(item, index, dockGridSettings)
    );
  }

  function getRootDirectoryStyle(item: DirectoryItem, index: number): CSSProperties {
    const position = getRootDirectoryPosition(item, index);

    return {
      left: `${position.x}px`,
      top: `${position.y}px`,
    };
  }

  function getResolvedLaunchGroupLayout(groupName: string, itemCount: number): LaunchGroupLayout {
    return (
      resolvedLaunchGroupLayouts[groupName] ??
      resolveLaunchGroupLayouts(
        [
          {
            itemCount,
            name: groupName,
          },
        ],
        launchGroupLayouts,
        rootLaunchFlowWidth,
        launchGroupsWidth,
        dockGridSettings,
        rootLaunchEntryRects,
      )[groupName] ??
      getAutoGroupLayout(itemCount)
    );
  }

  function getGroupLayoutStyle(
    groupName: string,
    itemCount: number,
    resolvedLayout?: LaunchGroupLayout,
    includePosition = true,
  ): CSSProperties {
    const layout = resolvedLayout ?? getResolvedLaunchGroupLayout(groupName, itemCount);

    return {
      "--group-columns": `${layout.columns}`,
      "--group-height": `${layout.height}px`,
      "--group-width": `${layout.width}px`,
      ...(includePosition && layout.position
        ? {
            left: `${layout.position.x}px`,
            top: `${layout.position.y}px`,
          }
        : {}),
      } as CSSProperties;
  }

  function getLaunchGroupPageLabel(pageIndex: number, pageCount: number): string {
    return appLanguage === "zh"
      ? `第 ${pageIndex + 1} 页，共 ${pageCount} 页`
      : `Page ${pageIndex + 1} of ${pageCount}`;
  }

  function getLaunchGroupPage(
    groupName: string,
    itemCount: number,
    layout: LaunchGroupLayout,
  ): number {
    return clampLaunchGroupPage(launchGroupPages[groupName] ?? 0, itemCount, layout);
  }

  function updateLaunchGroupPage(
    groupName: string,
    itemCount: number,
    layout: LaunchGroupLayout,
    getNextPage: (currentPage: number, pageCount: number) => number,
  ) {
    setLaunchGroupPages((pages) => {
      const pageCount = getLaunchGroupPageCount(itemCount, layout);
      const currentPage = clampLaunchGroupPage(pages[groupName] ?? 0, itemCount, layout);
      const nextPage = clampInteger(getNextPage(currentPage, pageCount), 0, pageCount - 1);
      const storedPage = pages[groupName] ?? 0;

      if (storedPage === nextPage || (nextPage === 0 && pages[groupName] === undefined)) {
        return pages;
      }

      const nextPages = { ...pages };

      if (nextPage === 0) {
        delete nextPages[groupName];
      } else {
        nextPages[groupName] = nextPage;
      }

      return nextPages;
    });
  }

  function setLaunchGroupPage(
    groupName: string,
    page: number,
    itemCount: number,
    layout: LaunchGroupLayout,
  ) {
    updateLaunchGroupPage(groupName, itemCount, layout, () => page);
  }

  function turnLaunchGroupPage(
    groupName: string,
    direction: -1 | 1,
    itemCount: number,
    layout: LaunchGroupLayout,
  ) {
    updateLaunchGroupPage(groupName, itemCount, layout, (currentPage) => currentPage + direction);
  }

  function getLaunchGroupSwipeOffset(
    deltaX: number,
    startPage: number,
    pageCount: number,
    layout: LaunchGroupLayout,
  ): number {
    const width = Math.max(layout.width, 1);
    const isPullingPastStart = startPage === 0 && deltaX > 0;
    const isPullingPastEnd = startPage === pageCount - 1 && deltaX < 0;
    const dampedDeltaX = isPullingPastStart || isPullingPastEnd ? deltaX * 0.32 : deltaX;

    return clampNumber(dampedDeltaX, width * -0.94, width * 0.94, 0);
  }

  function getLaunchGroupSwipeTargetPage(session: LaunchGroupSwipeSession): number {
    const threshold = Math.min(
      Math.max(session.layout.width * 0.22, launchGroupPageSwipeThreshold),
      96,
    );

    if (Math.abs(session.offsetX) < threshold) {
      return session.startPage;
    }

    return clampInteger(
      session.startPage + (session.offsetX < 0 ? 1 : -1),
      0,
      session.pageCount - 1,
    );
  }

  function getLaunchPageStripStyle(
    groupName: string,
    currentPage: number,
    layout: LaunchGroupLayout,
  ): CSSProperties {
    const swipeState =
      launchGroupSwipeState?.groupName === groupName ? launchGroupSwipeState : null;
    const offsetX = swipeState?.offsetX ?? 0;
    const tilt = clampNumber((offsetX / Math.max(layout.width, 1)) * -2.4, -2.4, 2.4, 0);

    return {
      "--launch-swipe-tilt": `${tilt}deg`,
      transform: `translate3d(calc(${-currentPage * 100}% + ${offsetX}px), 0, 0)`,
    } as CSSProperties;
  }

  function handleLaunchGroupWheel(
    groupName: string,
    itemCount: number,
    layout: LaunchGroupLayout,
    event: ReactWheelEvent<HTMLElement>,
  ) {
    if (getLaunchGroupPageCount(itemCount, layout) <= 1) {
      return;
    }

    if (
      Math.abs(event.deltaX) < 1 ||
      Math.abs(event.deltaX) <= Math.abs(event.deltaY)
    ) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();

    const now = Date.now();
    const wheelState = launchGroupWheelTurnRef.current[groupName] ?? {
      deltaX: 0,
      lastTurnAt: 0,
    };

    if (now - wheelState.lastTurnAt < launchGroupWheelPageCooldownMs) {
      wheelState.deltaX = 0;
      launchGroupWheelTurnRef.current[groupName] = wheelState;
      return;
    }

    if (Math.sign(wheelState.deltaX) !== 0 && Math.sign(wheelState.deltaX) !== Math.sign(event.deltaX)) {
      wheelState.deltaX = 0;
    }

    wheelState.deltaX += event.deltaX;

    if (Math.abs(wheelState.deltaX) < launchGroupWheelPageThreshold) {
      launchGroupWheelTurnRef.current[groupName] = wheelState;
      return;
    }

    wheelState.lastTurnAt = now;
    turnLaunchGroupPage(groupName, wheelState.deltaX > 0 ? 1 : -1, itemCount, layout);
    wheelState.deltaX = 0;
    launchGroupWheelTurnRef.current[groupName] = wheelState;
  }

  function handleLaunchGroupPagerPointerDownCapture(
    groupName: string,
    itemCount: number,
    layout: LaunchGroupLayout,
    event: ReactPointerEvent<HTMLElement>,
  ) {
    const pageCount = getLaunchGroupPageCount(itemCount, layout);

    if (
      event.button !== 0 ||
      pageCount <= 1 ||
      !(event.target instanceof Element) ||
      event.target.closest(
        ".launch-app-delete, .launch-group-corner, .launch-group-drag-handle, .launch-group-name, .launch-page-dot",
      )
    ) {
      return;
    }

    const sourceItemId =
      event.target.closest<HTMLElement>("[data-launch-item-id]")?.dataset.launchItemId;
    const session: LaunchGroupSwipeSession = {
      groupName,
      hasClaimed: false,
      itemCount,
      layout,
      offsetX: 0,
      pageCount,
      sourceItemId,
      startPage: getLaunchGroupPage(groupName, itemCount, layout),
      startX: event.clientX,
      startY: event.clientY,
    };

    launchGroupSwipeSessionRef.current = session;

    const handlePointerMove = (moveEvent: PointerEvent) => {
      const activeSession = launchGroupSwipeSessionRef.current;

      if (!activeSession || activeSession !== session) {
        return;
      }

      const deltaX = moveEvent.clientX - activeSession.startX;
      const deltaY = moveEvent.clientY - activeSession.startY;
      const absoluteDeltaX = Math.abs(deltaX);
      const absoluteDeltaY = Math.abs(deltaY);

      if (!activeSession.hasClaimed) {
        if (
          absoluteDeltaX < launchGroupPageClaimThreshold ||
          absoluteDeltaX <= absoluteDeltaY * 1.15
        ) {
          return;
        }

        activeSession.hasClaimed = true;
        clearLaunchLongPressTimer();

        if (activeSession.sourceItemId) {
          suppressNextLaunchItemClick(activeSession.sourceItemId);
        }
      }

      moveEvent.preventDefault();
      activeSession.offsetX = getLaunchGroupSwipeOffset(
        deltaX,
        activeSession.startPage,
        activeSession.pageCount,
        activeSession.layout,
      );
      setLaunchGroupSwipeState({
        groupName: activeSession.groupName,
        isDragging: true,
        offsetX: activeSession.offsetX,
      });
    };

    const handlePointerUp = () => {
      const activeSession = launchGroupSwipeSessionRef.current;

      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("pointerup", handlePointerUp);
      window.removeEventListener("pointercancel", handlePointerUp);

      if (activeSession === session && activeSession.hasClaimed) {
        const targetPage = getLaunchGroupSwipeTargetPage(activeSession);

        if (activeSession.sourceItemId) {
          suppressNextLaunchItemClick(activeSession.sourceItemId);
        }

        setLaunchGroupPage(
          activeSession.groupName,
          targetPage,
          activeSession.itemCount,
          activeSession.layout,
        );
        setLaunchGroupSwipeState(null);
      }

      if (activeSession === session) {
        launchGroupSwipeSessionRef.current = null;
      }
    };

    window.addEventListener("pointermove", handlePointerMove);
    window.addEventListener("pointerup", handlePointerUp);
    window.addEventListener("pointercancel", handlePointerUp);
  }

  function getLaunchGroupsStyle(): CSSProperties {
    const rootGridWidth = getRootLaunchGridWidth(dockGridSettings);

    return {
      "--launch-groups-scale": launchGroupsScale,
      "--launch-groups-width": `${launchGroupsCanvasWidth}px`,
      "--launch-groups-height": `${launchGroupsCanvasHeight}px`,
      "--launch-root-grid-height": `${getRootLaunchGridHeight(dockGridSettings)}px`,
      "--launch-root-grid-left": `${(launchGroupsCanvasWidth - rootGridWidth) / 2}px`,
      "--launch-root-grid-width": `${getRootLaunchGridWidth(dockGridSettings)}px`,
      "--launch-root-flow-width": `${rootLaunchFlowWidth}px`,
    } as CSSProperties;
  }

  function getAvailableRootLaunchEntryPosition(
    items: LaunchItem[],
    preferredPosition: LaunchPosition,
    excludedItemId?: string,
    excludedGroupName?: string,
  ): LaunchPosition | null {
    const occupiedPositions = getOccupiedRootLaunchPositionKeys(
      items,
      dockGridSettings,
      excludedItemId,
    );

    launchGroups.forEach((group) => {
      if (group.name === excludedGroupName) {
        return;
      }

      const position = resolvedRootEntryPositions.groups.get(group.name);

      if (position) {
        occupiedPositions.add(getRootLaunchPositionKey(position, dockGridSettings));
      }
    });

    return getNearestAvailableRootLaunchPosition(
      occupiedPositions,
      preferredPosition,
      dockGridSettings,
    );
  }

  function getAvailableDirectoryPosition(
    items: DirectoryItem[],
    preferredPosition: LaunchPosition,
    excludedItemId?: string,
  ): LaunchPosition | null {
    return getNearestAvailableRootLaunchPosition(
      getOccupiedRootDirectoryPositionKeys(items, dockGridSettings, excludedItemId),
      preferredPosition,
      dockGridSettings,
    );
  }

  function moveLaunchItemToRootByInsertion(
    itemId: string,
    target: LaunchRootInsertionTarget,
  ): boolean {
    const movingItem = launchItems.find((item) => item.id === itemId);

    if (!movingItem) {
      return false;
    }

    const nextEntries = getRootEntriesWithInsertedItem(
      rootLaunchEntries,
      movingItem,
      target,
      dockGridSettings,
      launchGroupLayouts,
    );

    if (!nextEntries) {
      return false;
    }

    const nextPositions = getRootEntryPositionsFromOrder(nextEntries, dockGridSettings);
    const itemSortOrders = new Map<string, number>();

    nextEntries.forEach((entry, index) => {
      if (entry.kind === "item") {
        itemSortOrders.set(entry.item.id, index);
      }
    });

    setLaunchItems((items) => {
      let didChange = false;
      const nextItems = items.map((item) => {
        const position = nextPositions.items.get(item.id);
        const isMovingItem = item.id === itemId;
        const isRootItem = getLaunchGroupKey(item.group) === rootLaunchGroup;

        if (!position || (!isMovingItem && !isRootItem)) {
          return item;
        }

        const nextGroup = isMovingItem ? rootLaunchGroup : item.group;
        const nextSortOrder = itemSortOrders.get(item.id);

        if (
          getLaunchGroupKey(nextGroup) === getLaunchGroupKey(item.group) &&
          item.position?.x === position.x &&
          item.position?.y === position.y &&
          item.sortOrder === nextSortOrder
        ) {
          return item;
        }

        didChange = true;
        return {
          ...item,
          group: nextGroup,
          position,
          sortOrder: nextSortOrder,
        };
      });

      return didChange ? normalizeSingleItemLaunchGroups(nextItems, nextPositions.groups) : items;
    });

    setLaunchGroupLayouts((layouts) => {
      const nextLayouts = { ...layouts };
      let didChange = false;

      nextPositions.groups.forEach((position, groupName) => {
        const group = launchGroups.find((launchGroup) => launchGroup.name === groupName);
        const layout = nextLayouts[groupName] ?? getAutoGroupLayout(group?.items.length ?? 2);

        if (
          layout.manualPosition &&
          layout.position?.x === position.x &&
          layout.position?.y === position.y
        ) {
          return;
        }

        nextLayouts[groupName] = {
          ...layout,
          manualPosition: true,
          position,
        };
        didChange = true;
      });

      return didChange ? nextLayouts : layouts;
    });

    return true;
  }

  function getPreferredLaunchGroupRootPosition(
    groupName: string,
    fallbackIndex: number,
    groupPositionOverrides: Map<string, LaunchPosition> = new Map(),
  ): LaunchPosition {
    return (
      groupPositionOverrides.get(groupName) ??
      resolvedRootEntryPositions.groups.get(groupName) ??
      launchGroupLayouts[groupName]?.position ??
      getFallbackRootLaunchPosition(fallbackIndex, dockGridSettings)
    );
  }

  function normalizeSingleItemLaunchGroups(
    items: LaunchItem[],
    groupPositionOverrides: Map<string, LaunchPosition> = new Map(),
  ): LaunchItem[] {
    const groupedItems = new Map<string, LaunchItem[]>();

    items.forEach((item) => {
      const groupName = getLaunchGroupKey(item.group);

      if (groupName === rootLaunchGroup) {
        return;
      }

      groupedItems.set(groupName, [...(groupedItems.get(groupName) ?? []), item]);
    });

    const singleItemGroups = [...groupedItems.entries()].filter(
      ([, groupItems]) => groupItems.length === 1,
    );

    if (singleItemGroups.length === 0) {
      return items;
    }

    const releasedItemIds = new Set(singleItemGroups.map(([, groupItems]) => groupItems[0]?.id));
    const occupiedPositions = new Set<string>();
    const rootItems = items
      .filter(
        (item) =>
          getLaunchGroupKey(item.group) === rootLaunchGroup &&
          !releasedItemIds.has(item.id),
      )
      .sort(sortLaunchItems);
    const stableGroupNames = [...groupedItems.entries()]
      .filter(([, groupItems]) => groupItems.length > 1)
      .map(([groupName]) => groupName);

    rootItems.forEach((item, index) => {
      occupiedPositions.add(
        getRootLaunchPositionKey(
          getRootLaunchItemPosition(item, index, dockGridSettings),
          dockGridSettings,
        ),
      );
    });

    stableGroupNames.forEach((groupName, index) => {
      const position = getPreferredLaunchGroupRootPosition(
        groupName,
        rootItems.length + index,
        groupPositionOverrides,
      );

      occupiedPositions.add(getRootLaunchPositionKey(position, dockGridSettings));
    });

    const releasePositions = new Map<string, LaunchPosition>();

    singleItemGroups.forEach(([groupName, groupItems], index) => {
      const item = groupItems[0];

      if (!item) {
        return;
      }

      const preferredPosition = getPreferredLaunchGroupRootPosition(
        groupName,
        rootItems.length + stableGroupNames.length + index,
        groupPositionOverrides,
      );
      const position = getNearestAvailableRootLaunchPosition(
        occupiedPositions,
        preferredPosition,
        dockGridSettings,
      );

      if (!position) {
        return;
      }

      occupiedPositions.add(getRootLaunchPositionKey(position, dockGridSettings));
      releasePositions.set(item.id, position);
    });

    if (releasePositions.size === 0) {
      return items;
    }

    return items.map((item) => {
      const position = releasePositions.get(item.id);

      return position
        ? {
            ...item,
            group: rootLaunchGroup,
            position,
            sortOrder: undefined,
          }
        : item;
    });
  }

  function clearLaunchLongPressTimer() {
    if (launchLongPressTimerRef.current === null) {
      return;
    }

    window.clearTimeout(launchLongPressTimerRef.current);
    launchLongPressTimerRef.current = null;
  }

  function mergeLaunchItems(draggedId: string, targetId: string, insertAfterTarget: boolean) {
    const initialDraggedItem = launchItems.find((item) => item.id === draggedId);
    const initialTargetItem = launchItems.find((item) => item.id === targetId);
    const initialDraggedGroup = initialDraggedItem ? getLaunchGroupKey(initialDraggedItem.group) : null;
    const initialTargetGroup = initialTargetItem ? getLaunchGroupKey(initialTargetItem.group) : null;
    const shouldCreateInitialGroup =
      Boolean(initialDraggedItem && initialTargetItem) &&
      initialTargetGroup === rootLaunchGroup &&
      !(initialDraggedGroup === initialTargetGroup && initialTargetGroup !== rootLaunchGroup);
    const createdGroup = shouldCreateInitialGroup ? createId("launch-group") : null;
    const groupPositionOverrides = new Map<string, LaunchPosition>();

    if (createdGroup && initialTargetItem) {
      const rootItems = launchItems
        .filter((item) => getLaunchGroupKey(item.group) === rootLaunchGroup)
        .sort(sortLaunchItems);
      const targetRootIndex = Math.max(
        rootItems.findIndex((item) => item.id === targetId),
        0,
      );
      const targetPosition = getRootLaunchPosition(initialTargetItem, targetRootIndex);

      groupPositionOverrides.set(createdGroup, targetPosition);
      setLaunchGroupLayouts((layouts) => ({
        ...layouts,
        [createdGroup]: normalizeGroupLayout({
          ...getAutoGroupLayout(2),
          ...layouts[createdGroup],
          manualPosition: true,
          position: targetPosition,
        }),
      }));
      setOpenLaunchGroupName(createdGroup);
    }

    setLaunchItems((items) => {
      const draggedItem = items.find((item) => item.id === draggedId);
      const targetItem = items.find((item) => item.id === targetId);

      if (!draggedItem || !targetItem || draggedItem.id === targetItem.id) {
        return items;
      }

      const draggedGroup = getLaunchGroupKey(draggedItem.group);
      const targetGroup = getLaunchGroupKey(targetItem.group);

      if (draggedGroup === targetGroup && targetGroup !== rootLaunchGroup) {
        const groupItems = items
          .filter((item) => getLaunchGroupKey(item.group) === targetGroup)
          .sort(sortLaunchItems);
        const itemsWithoutDragged = groupItems.filter((item) => item.id !== draggedId);
        const targetIndex = itemsWithoutDragged.findIndex((item) => item.id === targetId);

        if (targetIndex < 0) {
          return items;
        }

        const insertIndex = targetIndex + (insertAfterTarget ? 1 : 0);
        const orderedItems = [
          ...itemsWithoutDragged.slice(0, insertIndex),
          draggedItem,
          ...itemsWithoutDragged.slice(insertIndex),
        ];
        const sortOrders = new Map(orderedItems.map((item, index) => [item.id, index]));

        return items.map((item) =>
          getLaunchGroupKey(item.group) === targetGroup
            ? {
                ...item,
                position: undefined,
                sortOrder: sortOrders.get(item.id),
              }
            : item,
        );
      }

      const shouldCreateGroup = targetGroup === rootLaunchGroup || draggedGroup === targetGroup;
      const destinationGroup = shouldCreateGroup ? (createdGroup ?? createId("launch-group")) : targetItem.group;
      const destinationGroupKey = getLaunchGroupKey(destinationGroup);

      if (shouldCreateGroup) {
        const orderedIds = insertAfterTarget ? [targetId, draggedId] : [draggedId, targetId];
        const nextItems = items.map((item) => {
          const sortOrder = orderedIds.indexOf(item.id);

          if (sortOrder >= 0) {
            return {
              ...item,
              group: destinationGroup,
              position: undefined,
              sortOrder,
            };
          }

          return item;
        });

        return normalizeSingleItemLaunchGroups(nextItems, groupPositionOverrides);
      }

      const targetGroupItems = items
        .filter((item) => getLaunchGroupKey(item.group) === destinationGroupKey && item.id !== draggedId)
        .sort(sortLaunchItems);
      const targetIndex = targetGroupItems.findIndex((item) => item.id === targetId);
      const insertIndex = targetIndex < 0 ? targetGroupItems.length : targetIndex + (insertAfterTarget ? 1 : 0);
      const orderedItems = [
        ...targetGroupItems.slice(0, insertIndex),
        draggedItem,
        ...targetGroupItems.slice(insertIndex),
      ];
      const sortOrders = new Map(orderedItems.map((item, index) => [item.id, index]));

      const nextItems = items.map((item) => {
        if (item.id === draggedItem.id) {
          return {
            ...item,
            group: destinationGroup,
            position: undefined,
            sortOrder: sortOrders.get(item.id),
          };
        }

        if (getLaunchGroupKey(item.group) === destinationGroupKey) {
          return {
            ...item,
            sortOrder: sortOrders.get(item.id),
          };
        }

        return item;
      });

      return normalizeSingleItemLaunchGroups(nextItems, groupPositionOverrides);
    });
  }

  function moveLaunchItemToRoot(itemId: string, position: LaunchPosition) {
    setLaunchItems((items) => {
      const movingItem = items.find((item) => item.id === itemId);
      const movingItemGroup = movingItem ? getLaunchGroupKey(movingItem.group) : rootLaunchGroup;
      const shouldReleaseSourceGroup =
        movingItemGroup !== rootLaunchGroup &&
        items.filter((item) => getLaunchGroupKey(item.group) === movingItemGroup).length <= 1;
      const nextPosition = getAvailableRootLaunchEntryPosition(
        items,
        position,
        itemId,
        shouldReleaseSourceGroup ? movingItemGroup : undefined,
      );

      if (!nextPosition) {
        return items;
      }

      const nextItems = items.map((item) =>
        item.id === itemId
          ? {
              ...item,
              group: rootLaunchGroup,
              position: nextPosition,
              sortOrder: undefined,
            }
          : item,
      );

      return normalizeSingleItemLaunchGroups(nextItems);
    });
  }

  function moveLaunchItemToGroup(itemId: string, sourceGroup: string, destinationGroup: string) {
    const sourceGroupKey = getLaunchGroupKey(sourceGroup);
    const destinationGroupKey = getLaunchGroupKey(destinationGroup);

    if (destinationGroupKey === rootLaunchGroup || sourceGroupKey === destinationGroupKey) {
      return;
    }

    setLaunchItems((items) => {
      const nextSortOrder = getNextGroupSortOrder(items, destinationGroupKey);
      const nextItems = items.map((item) =>
        item.id === itemId
          ? {
              ...item,
              group: destinationGroupKey,
              position: undefined,
              sortOrder: nextSortOrder,
            }
          : item,
      );

      return normalizeSingleItemLaunchGroups(nextItems);
    });
  }

  function moveLaunchGroupToRoot(groupName: string, position: LaunchPosition) {
    const group = launchGroups.find((launchGroup) => launchGroup.name === groupName);
    const nextPosition = getAvailableRootLaunchEntryPosition(
      launchItems,
      position,
      undefined,
      groupName,
    );

    if (!group || !nextPosition) {
      return;
    }

    setLaunchGroupLayouts((layouts) => {
      const currentLayout = layouts[groupName] ?? getAutoGroupLayout(group.items.length);

      return {
        ...layouts,
        [groupName]: {
          ...currentLayout,
          manualPosition: true,
          position: nextPosition,
        },
      };
    });
  }

  function moveDirectoryItemToRoot(itemId: string, position: LaunchPosition) {
    setDirectoryItems((items) => {
      const nextPosition = getAvailableDirectoryPosition(items, position, itemId);

      if (!nextPosition) {
        return items;
      }

      return items.map((item) =>
        item.id === itemId
          ? {
              ...item,
              position: nextPosition,
              sortOrder: undefined,
            }
          : item,
      );
    });
  }

  function suppressNextLaunchItemClick(itemId: string) {
    suppressLaunchItemIdRef.current = itemId;
    window.setTimeout(() => {
      if (suppressLaunchItemIdRef.current === itemId) {
        suppressLaunchItemIdRef.current = null;
      }
    }, 200);
  }

  function suppressNextLaunchGroupClick(groupName: string) {
    suppressLaunchGroupNameRef.current = groupName;
    window.setTimeout(() => {
      if (suppressLaunchGroupNameRef.current === groupName) {
        suppressLaunchGroupNameRef.current = null;
      }
    }, 200);
  }

  function suppressNextDirectoryItemClick(itemId: string) {
    suppressDirectoryItemIdRef.current = itemId;
    window.setTimeout(() => {
      if (suppressDirectoryItemIdRef.current === itemId) {
        suppressDirectoryItemIdRef.current = null;
      }
    }, 200);
  }

  function handleLaunchItemClick(item: LaunchItem) {
    if (suppressLaunchItemIdRef.current === item.id) {
      suppressLaunchItemIdRef.current = null;
      return;
    }

    if (isLaunchEditMode) {
      return;
    }

    void handleLaunch(item);
  }

  function handleDirectoryItemClick(item: DirectoryItem) {
    if (suppressDirectoryItemIdRef.current === item.id) {
      suppressDirectoryItemIdRef.current = null;
      return;
    }

    if (isLaunchEditMode) {
      return;
    }

    void handleOpenDirectory(item);
  }

  function getValidLaunchDropIntent(
    itemId: string,
    x: number,
    y: number,
    previousIntent?: LaunchDropIntent | null,
  ): LaunchDropIntent | null {
    const isEditingLaunch = launchEditModeRef.current;
    const sourceItem = launchItems.find((launchItem) => launchItem.id === itemId);
    const sourceGroup = sourceItem ? getLaunchGroupKey(sourceItem.group) : rootLaunchGroup;

    if (sourceGroup !== rootLaunchGroup && isPointOutsideOpenLaunchGroupPanel(x, y)) {
      return {
        insertAfterTarget: true,
        rootDropAction: isEditingLaunch ? "insert" : "position",
        targetAction: "insert",
        targetGroup: rootLaunchGroup,
        targetId: null,
      };
    }

    const targetPlacement = getLaunchTargetPlacementFromPoint(itemId, x, y);
    const targetItem = targetPlacement
      ? launchItems.find((launchItem) => launchItem.id === targetPlacement.targetId)
      : undefined;

    if (targetPlacement && targetItem) {
      return {
        ...targetPlacement,
        targetAction: isEditingLaunch ? "insert" : "merge",
        targetGroup: getLaunchGroupKey(targetItem.group),
      };
    }

    const groupElement = getLaunchGroupElementBelowPoint(x, y);
    const groupName = groupElement?.dataset.launchGroupName;

    if (groupName) {
      const targetGroup = getLaunchGroupKey(groupName);
      const previousTargetGroup = previousIntent?.targetGroup
        ? getLaunchGroupKey(previousIntent.targetGroup)
        : null;

      if (
        previousIntent?.targetId &&
        previousIntent.targetAction === "insert" &&
        previousTargetGroup === targetGroup &&
        isDragOverLaunchItemSlot(itemId, x, y)
      ) {
        return previousIntent;
      }

      return {
        insertAfterTarget: true,
        targetAction: isEditingLaunch ? "insert" : "merge",
        targetGroup,
        targetId: null,
      };
    }

    if (getLaunchRootZoneBelowPoint(x, y)) {
      return {
        insertAfterTarget: true,
        rootDropAction: isEditingLaunch ? "insert" : "position",
        targetAction: "insert",
        targetGroup: rootLaunchGroup,
        targetId: null,
      };
    }

    return null;
  }

  function getPreviewGroupItems(groupName: string, items: LaunchItem[]): LaunchItem[] {
    if (!launchDragState || !draggedLaunchItem) {
      return items;
    }

    const groupKey = getLaunchGroupKey(groupName);
    const sourceGroup = getLaunchGroupKey(draggedLaunchItem.group);
    const targetGroup = launchDragState.targetGroup
      ? getLaunchGroupKey(launchDragState.targetGroup)
      : null;

    if (sourceGroup !== groupKey && targetGroup !== groupKey) {
      return items;
    }

    const itemsWithoutDragged = items.filter((launchItem) => launchItem.id !== draggedLaunchItem.id);

    if (targetGroup !== groupKey) {
      return sourceGroup === groupKey ? items : itemsWithoutDragged;
    }

    if (!launchDragState.targetId) {
      return sourceGroup === groupKey ? items : itemsWithoutDragged;
    }

    const targetIndex = itemsWithoutDragged.findIndex(
      (launchItem) => launchItem.id === launchDragState.targetId,
    );

    if (targetIndex < 0) {
      return [...itemsWithoutDragged, draggedLaunchItem];
    }

    const insertIndex = targetIndex + (launchDragState.insertAfterTarget ? 1 : 0);

    return [
      ...itemsWithoutDragged.slice(0, insertIndex),
      draggedLaunchItem,
      ...itemsWithoutDragged.slice(insertIndex),
    ];
  }

  function handleLaunchItemPointerDown(
    item: LaunchItem,
    event: ReactPointerEvent<HTMLButtonElement>,
  ) {
    if (event.button !== 0) {
      return;
    }

    event.preventDefault();

    const iconRect = event.currentTarget
      .querySelector<HTMLElement>(".launch-app-icon")
      ?.getBoundingClientRect();
    const session: LaunchDragSession = {
      hasMoved: false,
      hasLongPressed: false,
      itemId: item.id,
      previewStartX: iconRect ? iconRect.left + iconRect.width / 2 : event.clientX,
      previewStartY: iconRect ? iconRect.top + iconRect.height / 2 : event.clientY,
      sourceGroup: getLaunchGroupKey(item.group),
      startX: event.clientX,
      startY: event.clientY,
    };
    launchDragSessionRef.current = session;

    if (!isLaunchEditMode) {
      clearLaunchLongPressTimer();
      launchLongPressTimerRef.current = window.setTimeout(() => {
        const activeSession = launchDragSessionRef.current;

        if (!activeSession || activeSession.itemId !== item.id || activeSession.hasMoved) {
          return;
        }

        activeSession.hasLongPressed = true;
        suppressNextLaunchItemClick(item.id);
        setLaunchEditMode(true);
        clearLaunchLongPressTimer();
      }, launchEditLongPressMs);
    }

    const handlePointerMove = (moveEvent: PointerEvent) => {
      if (launchGroupSwipeSessionRef.current?.hasClaimed) {
        return;
      }

      const activeSession = launchDragSessionRef.current;

      if (!activeSession || activeSession.itemId !== item.id) {
        return;
      }

      const deltaX = moveEvent.clientX - activeSession.startX;
      const deltaY = moveEvent.clientY - activeSession.startY;

      if (!activeSession.hasMoved && Math.hypot(deltaX, deltaY) < 6) {
        return;
      }

      clearLaunchLongPressTimer();
      activeSession.hasMoved = true;
      const dropIntent = getValidLaunchDropIntent(
        item.id,
        moveEvent.clientX,
        moveEvent.clientY,
        activeSession.lastDropIntent,
      );
      activeSession.lastDropIntent = dropIntent;
      const dropPosition = getLaunchDropShadowPosition(
        moveEvent.clientX,
        moveEvent.clientY,
        launchRootRef.current,
        dockGridSettings,
        launchGroupsScale,
      );
      const rootDropPosition = getRootLaunchPositionFromClient(
        moveEvent.clientX,
        moveEvent.clientY,
        launchRootRef.current,
        dockGridSettings,
        launchGroupsScale,
      );
      const previewPosition = getLaunchDragPreviewPosition(
        activeSession,
        moveEvent.clientX,
        moveEvent.clientY,
      );
      const isRootEmptyDrop = dropIntent?.targetGroup === rootLaunchGroup && !dropIntent.targetId;
      const rootDropAction = isRootEmptyDrop ? dropIntent.rootDropAction ?? "insert" : null;

      setLaunchDragState({
        dropX: dropPosition.x,
        dropY: dropPosition.y,
        insertAfterTarget: dropIntent?.insertAfterTarget ?? true,
        itemId: item.id,
        rootDropAction,
        rootInsertIndex:
          isRootEmptyDrop && rootDropAction !== "position"
            ? getRootLaunchGridIndex(rootDropPosition, dockGridSettings)
            : null,
        showDropShadow: isRootEmptyDrop,
        targetAction: dropIntent?.targetAction ?? "insert",
        targetGroup: dropIntent?.targetGroup ?? null,
        targetId: dropIntent?.targetId ?? null,
        x: previewPosition.x,
        y: previewPosition.y,
      });
    };

    const handlePointerUp = (upEvent: PointerEvent) => {
      const activeSession = launchDragSessionRef.current;
      const dropIntent =
        activeSession?.hasMoved && activeSession.itemId === item.id
          ? getValidLaunchDropIntent(
              item.id,
              upEvent.clientX,
              upEvent.clientY,
              activeSession.lastDropIntent,
            )
          : null;

      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("pointerup", handlePointerUp);
      clearLaunchLongPressTimer();
      launchDragSessionRef.current = null;
      setLaunchDragState(null);

      if (!activeSession || activeSession.itemId !== item.id) {
        return;
      }

      if (activeSession.hasLongPressed && !activeSession.hasMoved) {
        suppressNextLaunchItemClick(item.id);
        return;
      }

      if (!activeSession.hasMoved) {
        return;
      }

      suppressNextLaunchItemClick(item.id);

      if (dropIntent?.targetId) {
        const targetItem = launchItems.find((launchItem) => launchItem.id === dropIntent.targetId);

        if (
          targetItem &&
          getLaunchGroupKey(targetItem.group) === rootLaunchGroup &&
          dropIntent.targetAction === "insert" &&
          moveLaunchItemToRootByInsertion(item.id, {
            entryId: dropIntent.targetId,
            insertAfter: dropIntent.insertAfterTarget,
            kind: "entry",
          })
        ) {
          return;
        }

        mergeLaunchItems(
          item.id,
          dropIntent.targetId,
          dropIntent.insertAfterTarget,
        );
        return;
      }

      const dropGroupName = dropIntent?.targetGroup ?? null;

      if (dropGroupName && dropGroupName !== rootLaunchGroup) {
        moveLaunchItemToGroup(item.id, activeSession.sourceGroup, dropGroupName);
        return;
      }

      if (dropGroupName === rootLaunchGroup) {
        const rootPosition = getRootLaunchPositionFromClient(
          upEvent.clientX,
          upEvent.clientY,
          launchRootRef.current,
          dockGridSettings,
          launchGroupsScale,
        );

        if (dropIntent?.rootDropAction === "position") {
          moveLaunchItemToRoot(item.id, rootPosition);
          return;
        }

        if (
          moveLaunchItemToRootByInsertion(item.id, {
            index: getRootLaunchGridIndex(rootPosition, dockGridSettings),
            kind: "index",
          })
        ) {
          return;
        }

        moveLaunchItemToRoot(item.id, rootPosition);
      }
    };

    window.addEventListener("pointermove", handlePointerMove);
    window.addEventListener("pointerup", handlePointerUp);
  }

  function handleDirectoryItemPointerDown(
    item: DirectoryItem,
    event: ReactPointerEvent<HTMLButtonElement>,
  ) {
    if (event.button !== 0) {
      return;
    }

    event.preventDefault();

    const iconRect = event.currentTarget
      .querySelector<HTMLElement>(".directory-icon")
      ?.getBoundingClientRect();
    const session: DirectoryDragSession = {
      hasMoved: false,
      hasLongPressed: false,
      itemId: item.id,
      previewStartX: iconRect ? iconRect.left + iconRect.width / 2 : event.clientX,
      previewStartY: iconRect ? iconRect.top + iconRect.height / 2 : event.clientY,
      startX: event.clientX,
      startY: event.clientY,
    };
    directoryDragSessionRef.current = session;

    if (!isLaunchEditMode) {
      clearLaunchLongPressTimer();
      launchLongPressTimerRef.current = window.setTimeout(() => {
        const activeSession = directoryDragSessionRef.current;

        if (!activeSession || activeSession.itemId !== item.id || activeSession.hasMoved) {
          return;
        }

        activeSession.hasLongPressed = true;
        suppressNextDirectoryItemClick(item.id);
        setLaunchEditMode(true);
        clearLaunchLongPressTimer();
      }, launchEditLongPressMs);
    }

    const handlePointerMove = (moveEvent: PointerEvent) => {
      const activeSession = directoryDragSessionRef.current;

      if (!activeSession || activeSession.itemId !== item.id) {
        return;
      }

      const deltaX = moveEvent.clientX - activeSession.startX;
      const deltaY = moveEvent.clientY - activeSession.startY;

      if (!activeSession.hasMoved && Math.hypot(deltaX, deltaY) < 6) {
        return;
      }

      moveEvent.preventDefault();
      clearLaunchLongPressTimer();
      activeSession.hasMoved = true;

      const dropPosition = getLaunchDropShadowPosition(
        moveEvent.clientX,
        moveEvent.clientY,
        launchRootRef.current,
        dockGridSettings,
        launchGroupsScale,
      );
      const previewPosition = getLaunchDragPreviewPosition(
        activeSession,
        moveEvent.clientX,
        moveEvent.clientY,
      );

      setDirectoryDragState({
        dropX: dropPosition.x,
        dropY: dropPosition.y,
        itemId: item.id,
        showDropShadow: Boolean(getLaunchRootZoneBelowPoint(moveEvent.clientX, moveEvent.clientY)),
        x: previewPosition.x,
        y: previewPosition.y,
      });
    };

    const handlePointerUp = (upEvent: PointerEvent) => {
      const activeSession = directoryDragSessionRef.current;

      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("pointerup", handlePointerUp);
      window.removeEventListener("pointercancel", handlePointerUp);
      clearLaunchLongPressTimer();
      directoryDragSessionRef.current = null;
      setDirectoryDragState(null);

      if (!activeSession || activeSession.itemId !== item.id) {
        return;
      }

      if (activeSession.hasLongPressed && !activeSession.hasMoved) {
        suppressNextDirectoryItemClick(item.id);
        return;
      }

      if (!activeSession.hasMoved) {
        return;
      }

      suppressNextDirectoryItemClick(item.id);

      if (getLaunchRootZoneBelowPoint(upEvent.clientX, upEvent.clientY)) {
        moveDirectoryItemToRoot(
          item.id,
          getRootLaunchPositionFromClient(
            upEvent.clientX,
            upEvent.clientY,
            launchRootRef.current,
            dockGridSettings,
            launchGroupsScale,
          ),
        );
      }
    };

    window.addEventListener("pointermove", handlePointerMove);
    window.addEventListener("pointerup", handlePointerUp);
    window.addEventListener("pointercancel", handlePointerUp);
  }

  function handleLaunchGroupFolderPointerDown(
    group: LaunchGroupView,
    event: ReactPointerEvent<HTMLButtonElement>,
  ) {
    if (event.button !== 0) {
      return;
    }

    event.preventDefault();

    const iconRect = event.currentTarget
      .querySelector<HTMLElement>(".launch-folder-icon")
      ?.getBoundingClientRect();
    const session: LaunchGroupDragSession = {
      groupName: group.name,
      hasMoved: false,
      hasLongPressed: false,
      previewStartX: iconRect ? iconRect.left + iconRect.width / 2 : event.clientX,
      previewStartY: iconRect ? iconRect.top + iconRect.height / 2 : event.clientY,
      startX: event.clientX,
      startY: event.clientY,
    };
    launchGroupDragSessionRef.current = session;

    if (!isLaunchEditMode) {
      clearLaunchLongPressTimer();
      launchLongPressTimerRef.current = window.setTimeout(() => {
        const activeSession = launchGroupDragSessionRef.current;

        if (!activeSession || activeSession.groupName !== group.name || activeSession.hasMoved) {
          return;
        }

        activeSession.hasLongPressed = true;
        suppressNextLaunchGroupClick(group.name);
        setLaunchEditMode(true);
        clearLaunchLongPressTimer();
      }, launchEditLongPressMs);
    }

    const handlePointerMove = (moveEvent: PointerEvent) => {
      const activeSession = launchGroupDragSessionRef.current;

      if (!activeSession || activeSession.groupName !== group.name) {
        return;
      }

      const deltaX = moveEvent.clientX - activeSession.startX;
      const deltaY = moveEvent.clientY - activeSession.startY;

      if (!activeSession.hasMoved && Math.hypot(deltaX, deltaY) < 6) {
        return;
      }

      moveEvent.preventDefault();
      clearLaunchLongPressTimer();
      activeSession.hasMoved = true;
      setOpenLaunchGroupName((currentGroupName) =>
        currentGroupName === group.name ? null : currentGroupName,
      );

      const dropPosition = getLaunchDropShadowPosition(
        moveEvent.clientX,
        moveEvent.clientY,
        launchRootRef.current,
        dockGridSettings,
        launchGroupsScale,
      );
      const previewPosition = getLaunchDragPreviewPosition(
        activeSession,
        moveEvent.clientX,
        moveEvent.clientY,
      );

      setLaunchGroupDragState({
        dropX: dropPosition.x,
        dropY: dropPosition.y,
        groupName: group.name,
        showDropShadow: Boolean(getLaunchRootZoneBelowPoint(moveEvent.clientX, moveEvent.clientY)),
        x: previewPosition.x,
        y: previewPosition.y,
      });
    };

    const handlePointerUp = (upEvent: PointerEvent) => {
      const activeSession = launchGroupDragSessionRef.current;

      window.removeEventListener("pointermove", handlePointerMove);
      window.removeEventListener("pointerup", handlePointerUp);
      window.removeEventListener("pointercancel", handlePointerUp);
      clearLaunchLongPressTimer();
      launchGroupDragSessionRef.current = null;
      setLaunchGroupDragState(null);

      if (!activeSession || activeSession.groupName !== group.name) {
        return;
      }

      if (activeSession.hasLongPressed && !activeSession.hasMoved) {
        suppressNextLaunchGroupClick(group.name);
        return;
      }

      if (!activeSession.hasMoved) {
        return;
      }

      suppressNextLaunchGroupClick(group.name);
      moveLaunchGroupToRoot(
        group.name,
        getRootLaunchPositionFromClient(
          upEvent.clientX,
          upEvent.clientY,
          launchRootRef.current,
          dockGridSettings,
          launchGroupsScale,
        ),
      );
    };

    window.addEventListener("pointermove", handlePointerMove);
    window.addEventListener("pointerup", handlePointerUp);
    window.addEventListener("pointercancel", handlePointerUp);
  }

  function handleDockViewPointerDown(event: ReactPointerEvent<HTMLDivElement>) {
    if (!(event.target instanceof Element)) {
      return;
    }

    if (
      openLaunchGroupName &&
      activeDockTab === "programs" &&
      !event.target.closest(".launch-group, .launch-group-folder")
    ) {
      setOpenLaunchGroupName(null);
    }

    if (!isLaunchEditMode) {
      return;
    }

    if (
      event.target.closest(
        ".dock-view-tabs, .launch-app, .directory-item, .floating-add-button, .launch-group-corner, .launch-group-drag-handle, .launch-group-folder, .launch-group-name, .launch-group-pager, .launch-page-dots",
      )
    ) {
      return;
    }

    setLaunchEditMode(false);
  }

  function renderLaunchApp(
    item: LaunchItem,
    options: { hidden?: boolean; rootIndex?: number; rootPositioned?: boolean } = {},
  ) {
    const [iconStart, iconEnd] = getIconPalette(item.name);
    const isDragging = launchDragState?.itemId === item.id;
    const isDropTarget =
      launchDragState?.targetId === item.id && launchDragState.targetAction === "merge";

    return (
      <div
        className={[
          "launch-app",
          options.rootPositioned ? "root-positioned" : "",
          isDragging ? "dragging" : "",
          isDropTarget ? "drop-target" : "",
        ]
          .filter(Boolean)
          .join(" ")}
        data-launch-item-id={options.hidden ? undefined : item.id}
        key={item.id}
        style={
          options.rootPositioned && options.rootIndex !== undefined
            ? getRootLaunchAppStyle(item, options.rootIndex)
            : undefined
        }
      >
        <button
          className="launch-app-button"
          aria-label={`${localizedCopy.launch}: ${item.name}`}
          type="button"
          draggable={false}
          tabIndex={options.hidden ? -1 : undefined}
          onClick={() => handleLaunchItemClick(item)}
          onDragStart={(event) => event.preventDefault()}
          onPointerDown={(event) => handleLaunchItemPointerDown(item, event)}
        >
          <span
            className={["launch-app-icon", item.iconDataUrl ? "has-custom-icon" : ""]
              .filter(Boolean)
              .join(" ")}
            style={
              {
                "--launch-icon-start": iconStart,
                "--launch-icon-end": iconEnd,
              } as CSSProperties
            }
          >
            <span>{getIconLabel(item.name)}</span>
            {item.iconDataUrl && (
              <img
                src={item.iconDataUrl}
                alt=""
                draggable={false}
                onError={(event) => {
                  event.currentTarget.style.display = "none";
                }}
              />
            )}
          </span>
          <span className="launch-app-name">{item.name}</span>
        </button>

        <button
          className="launch-app-delete"
          title={localizedCopy.deleteApp}
          type="button"
          tabIndex={options.hidden ? -1 : undefined}
          onPointerDown={(event) => event.stopPropagation()}
          onClick={(event) => {
            event.stopPropagation();
            setLaunchItems((items) =>
              normalizeSingleItemLaunchGroups(
                items.filter((launchItem) => launchItem.id !== item.id),
              ),
            );
          }}
        >
          <X size={14} strokeWidth={2.6} />
        </button>
      </div>
    );
  }

  function renderDirectoryItem(
    item: DirectoryItem,
    options: { rootIndex?: number; rootPositioned?: boolean } = {},
  ) {
    const isDragging = directoryDragState?.itemId === item.id;

    return (
      <div
        className={[
          "launch-app",
          "directory-item",
          options.rootPositioned ? "root-positioned" : "",
          isDragging ? "dragging" : "",
        ]
          .filter(Boolean)
          .join(" ")}
        data-directory-item-id={item.id}
        key={item.id}
        style={
          options.rootPositioned && options.rootIndex !== undefined
            ? getRootDirectoryStyle(item, options.rootIndex)
            : undefined
        }
      >
        <button
          className="launch-app-button directory-button"
          aria-label={`${localizedCopy.openDirectory}: ${item.name}`}
          title={item.path}
          type="button"
          draggable={false}
          onClick={() => handleDirectoryItemClick(item)}
          onDragStart={(event) => event.preventDefault()}
          onPointerDown={(event) => handleDirectoryItemPointerDown(item, event)}
        >
          {renderDirectoryIcon(item)}
          <span className="launch-app-name">{item.name}</span>
        </button>

        <button
          className="launch-app-delete"
          title={localizedCopy.deleteDirectory}
          type="button"
          onPointerDown={(event) => event.stopPropagation()}
          onClick={(event) => {
            event.stopPropagation();
            setDirectoryItems((items) =>
              normalizeRootDirectoryPositions(
                items.filter((directoryItem) => directoryItem.id !== item.id),
                dockGridSettings,
              ),
            );
          }}
        >
          <X size={14} strokeWidth={2.6} />
        </button>
      </div>
    );
  }

  function renderDirectoryIcon(item: DirectoryItem) {
    const iconDataUrl = item.iconDataUrl?.trim();

    return (
      <span
        className={["directory-icon", iconDataUrl ? "has-custom-icon" : ""]
          .filter(Boolean)
          .join(" ")}
        aria-hidden="true"
      >
        {iconDataUrl ? (
          <img src={iconDataUrl} alt="" draggable={false} />
        ) : (
          <Folder size={36} strokeWidth={1.75} />
        )}
      </span>
    );
  }

  function renderLaunchFolderThumbnail(item: LaunchItem) {
    const [iconStart, iconEnd] = getIconPalette(item.name);

    return (
      <span
        className={["launch-folder-mini-icon", item.iconDataUrl ? "has-custom-icon" : ""]
          .filter(Boolean)
          .join(" ")}
        key={item.id}
        style={
          {
            "--launch-icon-start": iconStart,
            "--launch-icon-end": iconEnd,
          } as CSSProperties
        }
      >
        <span>{getIconLabel(item.name).slice(0, 1)}</span>
        {item.iconDataUrl && (
          <img
            src={item.iconDataUrl}
            alt=""
            draggable={false}
            onError={(event) => {
              event.currentTarget.style.display = "none";
            }}
          />
        )}
      </span>
    );
  }

  function renderLaunchGroupFolder(group: LaunchGroupView) {
    const position = resolvedRootEntryPositions.groups.get(group.name);
    const previewItems = getPreviewGroupItems(group.name, group.items);
    const previewLimit = 9;
    const isDropTarget =
      launchDragState?.targetGroup === group.name && launchDragState.targetId === null;
    const isDragging = launchGroupDragState?.groupName === group.name;
    const isEditingName = editingLaunchGroupName === group.name;

    if (!position) {
      return null;
    }

    return (
      <div
        className={[
          "launch-group-folder",
          "root-positioned",
          openLaunchGroupName === group.name ? "open" : "",
          isDropTarget ? "drop-target" : "",
          isDragging ? "dragging" : "",
        ]
          .filter(Boolean)
          .join(" ")}
        data-launch-group-name={group.name}
        key={group.name}
        style={{
          left: `${position.x}px`,
          top: `${position.y}px`,
        }}
      >
        <button
          className="launch-folder-button"
          aria-label={`${localizedCopy.openGroup}: ${group.displayName}`}
          type="button"
          onPointerDown={(event) => handleLaunchGroupFolderPointerDown(group, event)}
          onClick={(event) => {
            event.stopPropagation();
            if (suppressLaunchGroupNameRef.current === group.name) {
              suppressLaunchGroupNameRef.current = null;
              return;
            }
            setOpenLaunchGroupName((currentGroupName) =>
              currentGroupName === group.name ? null : group.name,
            );
          }}
        >
          <span className="launch-folder-icon">
            {Array.from({ length: previewLimit }, (_, index) => {
              const item = previewItems[index];

              return item ? renderLaunchFolderThumbnail(item) : <span className="launch-folder-mini-empty" key={index} />;
            })}
          </span>
        </button>

        <div
          className={["launch-folder-name", isEditingName ? "editing" : ""]
            .filter(Boolean)
            .join(" ")}
          onDoubleClick={(event) => {
            event.preventDefault();
            event.stopPropagation();
            beginEditingLaunchGroupName(group.name, group.displayName);
          }}
          onPointerDown={(event) => event.stopPropagation()}
        >
          {isEditingName ? (
            <input
              className="launch-folder-name-input"
              aria-label={localizedCopy.groupNameEdit}
              ref={launchGroupNameInputRef}
              type="text"
              value={launchGroupNameDraft}
              maxLength={48}
              onBlur={commitEditingLaunchGroupName}
              onChange={(event) => setLaunchGroupNameDraft(event.currentTarget.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  event.preventDefault();
                  commitEditingLaunchGroupName();
                }

                if (event.key === "Escape") {
                  event.preventDefault();
                  cancelEditingLaunchGroupName();
                }
              }}
            />
          ) : (
            <button
              className="launch-folder-name-button"
              type="button"
            >
              {group.displayName}
            </button>
          )}
        </div>
      </div>
    );
  }

  function renderOpenLaunchGroupPanel() {
    if (!openLaunchGroup || !openLaunchGroupLayout) {
      return null;
    }

    const group = openLaunchGroup;
    const previewItems = getPreviewGroupItems(group.name, group.items);
    const groupLayout = openLaunchGroupLayout;
    const currentPage = getLaunchGroupPage(group.name, previewItems.length, groupLayout);
    const pageCount = getLaunchGroupPageCount(previewItems.length, groupLayout);
    const pageItems = getLaunchGroupPagedItems(previewItems, groupLayout);
    const swipeState = launchGroupSwipeState?.groupName === group.name ? launchGroupSwipeState : null;

    return (
      <div className="launch-group-overlay">
        <section
          className="launch-group open-panel"
          aria-label={group.displayName}
          data-launch-group-name={group.name}
          style={getGroupLayoutStyle(group.name, previewItems.length, groupLayout, false)}
        >
          <div
            className="launch-group-name"
            onPointerDown={(event) => event.stopPropagation()}
          >
            <span className="launch-group-name-text">{group.displayName}</span>
          </div>

          <div
            className={[
              "launch-group-pager",
              pageCount > 1 ? "can-page" : "",
              swipeState?.isDragging ? "dragging" : "",
            ]
              .filter(Boolean)
              .join(" ")}
            onPointerDownCapture={(event) =>
              handleLaunchGroupPagerPointerDownCapture(
                group.name,
                previewItems.length,
                groupLayout,
                event,
              )
            }
            onWheel={(event) =>
              handleLaunchGroupWheel(group.name, previewItems.length, groupLayout, event)
            }
          >
            <div
              className="launch-page-strip"
              style={getLaunchPageStripStyle(group.name, currentPage, groupLayout)}
            >
              {pageItems.map((items, pageIndex) => (
                <div
                  className="launch-icon-grid"
                  aria-hidden={pageIndex === currentPage ? undefined : true}
                  key={pageIndex}
                >
                  {items.map((item) =>
                    renderLaunchApp(item, {
                      hidden: pageIndex !== currentPage,
                    }),
                  )}
                </div>
              ))}
            </div>

            {pageCount > 1 && (
              <div
                className="launch-page-dots"
                aria-label={getLaunchGroupPageLabel(currentPage, pageCount)}
              >
                {Array.from({ length: pageCount }, (_, pageIndex) => (
                  <button
                    className={[
                      "launch-page-dot",
                      pageIndex === currentPage ? "active" : "",
                    ]
                      .filter(Boolean)
                      .join(" ")}
                    title={getLaunchGroupPageLabel(pageIndex, pageCount)}
                    aria-label={getLaunchGroupPageLabel(pageIndex, pageCount)}
                    aria-current={pageIndex === currentPage ? "page" : undefined}
                    type="button"
                    key={pageIndex}
                    onPointerDown={(event) => event.stopPropagation()}
                    onClick={(event) => {
                      event.stopPropagation();
                      setLaunchGroupPage(
                        group.name,
                        pageIndex,
                        previewItems.length,
                        groupLayout,
                      );
                    }}
                  />
                ))}
              </div>
            )}
          </div>
        </section>
      </div>
    );
  }

  useEffect(() => {
    const updateLanguage = () => setSystemLanguage(getSystemLanguage());

    window.addEventListener("languagechange", updateLanguage);
    return () => window.removeEventListener("languagechange", updateLanguage);
  }, []);

  useEffect(() => {
    void syncDockWindowMinimumSize(dockGridSettings).catch(() => undefined);
  }, [dockGridSettings]);

  useEffect(() => () => clearLaunchLongPressTimer(), []);

  useEffect(() => {
    setLaunchEditMode(false);
    setOpenLaunchGroupName(null);
    setLaunchDragState(null);
    setLaunchGroupDragState(null);
    setDirectoryDragState(null);
    setLaunchError(null);
    launchDragSessionRef.current = null;
    launchGroupDragSessionRef.current = null;
    directoryDragSessionRef.current = null;
  }, [activeDockTab]);

  useEffect(() => {
    function updateLaunchMeasurements() {
      setLaunchGroupsWidth(getRootLaunchGridWidth(dockGridSettings));

      const dockViewRect = dockViewRef.current?.getBoundingClientRect();
      const nextDockViewSize = {
        height: Math.max(dockViewRect?.height ?? 0, getRootLaunchGridHeight(dockGridSettings)),
        width: Math.max(dockViewRect?.width ?? 0, getRootLaunchGridWidth(dockGridSettings)),
      };

      setDockViewSize((currentSize) =>
        currentSize.height === nextDockViewSize.height && currentSize.width === nextDockViewSize.width
          ? currentSize
          : nextDockViewSize,
      );
    }

    updateLaunchMeasurements();
    window.addEventListener("resize", updateLaunchMeasurements);

    if (typeof ResizeObserver === "undefined") {
      return () => window.removeEventListener("resize", updateLaunchMeasurements);
    }

    const resizeObserver = new ResizeObserver(updateLaunchMeasurements);

    if (dockViewRef.current) {
      resizeObserver.observe(dockViewRef.current);
    }

    if (launchGroupsRef.current) {
      resizeObserver.observe(launchGroupsRef.current);
    }

    return () => {
      resizeObserver.disconnect();
      window.removeEventListener("resize", updateLaunchMeasurements);
    };
  }, [activeDockTab, activeMenu, directoryItems.length, dockGridSettings, launchItems.length]);

  useEffect(() => {
    setLaunchItems((items) => normalizeSingleItemLaunchGroups(items));
  }, [dockGridSettings, launchGroupLayouts, resolvedRootEntryPositions]);

  useEffect(() => {
    if (directoryDragState) {
      return;
    }

    setDirectoryItems((items) => {
      let didChange = false;
      const nextItems = items.map((item) => {
        const position = resolvedDirectoryPositions.get(item.id);

        if (!position || (item.position?.x === position.x && item.position?.y === position.y)) {
          return item;
        }

        didChange = true;
        return {
          ...item,
          position,
        };
      });

      return didChange ? nextItems : items;
    });
  }, [directoryDragState, resolvedDirectoryPositions]);

  useEffect(() => {
    const activeGroupNames = new Set(launchGroups.map((group) => group.name));

    if (openLaunchGroupName && !activeGroupNames.has(openLaunchGroupName)) {
      setOpenLaunchGroupName(null);
    }

    if (editingLaunchGroupName && !activeGroupNames.has(editingLaunchGroupName)) {
      cancelEditingLaunchGroupName();
    }

    setLaunchGroupNames((names) => {
      const nextNames = { ...names };
      let didChange = false;

      Object.keys(nextNames).forEach((groupName) => {
        if (activeGroupNames.has(groupName)) {
          return;
        }

        delete nextNames[groupName];
        didChange = true;
      });

      return didChange ? nextNames : names;
    });

    setLaunchGroupLayouts((layouts) => {
      const nextLayouts = { ...layouts };
      let didChange = false;

      Object.keys(nextLayouts).forEach((groupName) => {
        if (activeGroupNames.has(groupName)) {
          return;
        }

        delete nextLayouts[groupName];
        didChange = true;
      });

      return didChange ? nextLayouts : layouts;
    });
  }, [editingLaunchGroupName, launchGroups, openLaunchGroupName]);

  useEffect(() => {
    if (launchDragState || launchGroupDragState) {
      return;
    }

    setLaunchItems((items) => {
      let didChange = false;
      const nextItems = items.map((item) => {
        if (getLaunchGroupKey(item.group) !== rootLaunchGroup) {
          return item;
        }

        const position = resolvedRootEntryPositions.items.get(item.id);

        if (!position || (item.position?.x === position.x && item.position?.y === position.y)) {
          return item;
        }

        didChange = true;
        return {
          ...item,
          position,
        };
      });

      return didChange ? nextItems : items;
    });

    setLaunchGroupLayouts((layouts) => {
      const nextLayouts = { ...layouts };
      let didChange = false;

      launchGroups.forEach((group) => {
        const position = resolvedRootEntryPositions.groups.get(group.name);
        const layout = nextLayouts[group.name] ?? getAutoGroupLayout(group.items.length);

        if (!position || (layout.position?.x === position.x && layout.position?.y === position.y)) {
          return;
        }

        nextLayouts[group.name] = {
          ...layout,
          manualPosition: true,
          position,
        };
        didChange = true;
      });

      return didChange ? nextLayouts : layouts;
    });
  }, [launchDragState, launchGroupDragState, launchGroups, resolvedRootEntryPositions]);

  useEffect(() => {
    setLaunchGroupPages((pages) => {
      const nextPages: Record<string, number> = {};
      let didChange = false;

      launchGroups.forEach((group) => {
        const layout = resolvedLaunchGroupLayouts[group.name] ?? getAutoGroupLayout(group.items.length);
        const currentPage = pages[group.name] ?? 0;
        const nextPage = clampLaunchGroupPage(currentPage, group.items.length, layout);

        if (currentPage !== nextPage) {
          didChange = true;
        }

        if (nextPage > 0) {
          nextPages[group.name] = nextPage;
        }
      });

      if (
        Object.keys(pages).some(
          (groupName) => !launchGroups.some((group) => group.name === groupName),
        )
      ) {
        didChange = true;
      }

      return didChange ? nextPages : pages;
    });
  }, [launchGroups, resolvedLaunchGroupLayouts]);

  useEffect(() => {
    try {
      window.localStorage.setItem(languageStorageKey, languagePreference);
    } catch {
      return;
    }
  }, [languagePreference]);

  useEffect(() => {
    try {
      window.localStorage.setItem(floatingBallStyleStorageKey, floatingBallStyle);
    } catch {
      return;
    }
  }, [floatingBallStyle]);

  useEffect(() => {
    try {
      window.localStorage.setItem(dockIconVisibleStorageKey, String(dockIconVisible));
    } catch {
      return;
    }

    void invoke("set_dock_icon_visible", { visible: dockIconVisible }).catch(() => undefined);
  }, [dockIconVisible]);

  useEffect(() => {
    try {
      window.localStorage.setItem(dockGridSettingsStorageKey, JSON.stringify(dockGridSettings));
    } catch {
      return;
    }
  }, [dockGridSettings]);

  useEffect(() => {
    if (!editingLaunchGroupName) {
      return;
    }

    window.requestAnimationFrame(() => {
      launchGroupNameInputRef.current?.focus();
      launchGroupNameInputRef.current?.select();
    });
  }, [editingLaunchGroupName]);

  useEffect(() => {
    try {
      window.localStorage.setItem(launchItemsStorageKey, JSON.stringify(launchItems));
    } catch {
      return;
    }
  }, [launchItems]);

  useEffect(() => {
    try {
      window.localStorage.setItem(directoryItemsStorageKey, JSON.stringify(directoryItems));
    } catch {
      return;
    }
  }, [directoryItems]);

  useEffect(() => {
    const itemsNeedingIconRefresh = launchItems.filter((item) => {
      if (!shouldRefreshIconDataUrl(item.iconDataUrl)) {
        return false;
      }

      if (launchIconRefreshAttemptedPathsRef.current.has(item.path)) {
        return false;
      }

      launchIconRefreshAttemptedPathsRef.current.add(item.path);
      return true;
    });

    if (itemsNeedingIconRefresh.length === 0) {
      return;
    }

    let isCancelled = false;

    async function refreshLaunchIcons() {
      const refreshedApps = await Promise.all(
        itemsNeedingIconRefresh.map(async (item) => {
          try {
            const appInfo = await invoke<ApplicationInfo>("inspect_application", { appPath: item.path });
            const iconDataUrl = appInfo.iconDataUrl?.trim();

            return iconDataUrl ? { iconDataUrl, id: item.id } : null;
          } catch {
            return null;
          }
        }),
      );

      if (isCancelled) {
        return;
      }

      const iconsById = new Map(
        refreshedApps
          .filter((app): app is { iconDataUrl: string; id: string } => app !== null)
          .map((app) => [app.id, app.iconDataUrl]),
      );

      if (iconsById.size === 0) {
        return;
      }

      setLaunchItems((items) =>
        items.map((item) => {
          const iconDataUrl = iconsById.get(item.id);

          return iconDataUrl && item.iconDataUrl !== iconDataUrl ? { ...item, iconDataUrl } : item;
        }),
      );
    }

    void refreshLaunchIcons();

    return () => {
      isCancelled = true;
    };
  }, [launchItems]);

  useEffect(() => {
    const itemsNeedingIconRefresh = directoryItems.filter((item) => {
      if (!shouldRefreshDirectoryMetadata(item)) {
        return false;
      }

      if (directoryIconRefreshAttemptedPathsRef.current.has(item.path)) {
        return false;
      }

      directoryIconRefreshAttemptedPathsRef.current.add(item.path);
      return true;
    });

    if (itemsNeedingIconRefresh.length === 0) {
      return;
    }

    let isCancelled = false;

    async function refreshDirectoryIcons() {
      const refreshedDirectories = await Promise.all(
        itemsNeedingIconRefresh.map(async (item) => {
          try {
            const directoryInfo = await invoke<DirectoryInfo>("inspect_directory", {
              directoryPath: item.path,
            });
            const iconDataUrl = directoryInfo.iconDataUrl?.trim();

            return {
              comparisonPath: directoryInfo.comparisonPath,
              iconDataUrl: iconDataUrl || undefined,
              id: item.id,
              name: directoryInfo.name,
              path: directoryInfo.path,
            };
          } catch {
            return null;
          }
        }),
      );

      if (isCancelled) {
        return;
      }

      const directoriesById = new Map(
        refreshedDirectories
          .filter(
            (
              directory,
            ): directory is {
              comparisonPath: string;
              iconDataUrl: string | undefined;
              id: string;
              name: string;
              path: string;
            } => directory !== null,
          )
          .map((directory) => [directory.id, directory]),
      );

      if (directoriesById.size === 0) {
        return;
      }

      setDirectoryItems((items) =>
        items.map((item) => {
          const directory = directoriesById.get(item.id);

          if (!directory) {
            return item;
          }

          return {
            ...item,
            comparisonPath: directory.comparisonPath,
            iconDataUrl: directory.iconDataUrl ?? item.iconDataUrl,
            name: directory.name.trim() || item.name,
            path: directory.path,
          };
        }),
      );
    }

    void refreshDirectoryIcons();

    return () => {
      isCancelled = true;
    };
  }, [directoryItems]);

  useEffect(() => {
    try {
      window.localStorage.setItem(launchGroupNamesStorageKey, JSON.stringify(launchGroupNames));
    } catch {
      return;
    }
  }, [launchGroupNames]);

  useEffect(() => {
    try {
      window.localStorage.setItem(launchGroupLayoutsStorageKey, JSON.stringify(launchGroupLayouts));
    } catch {
      return;
    }
  }, [launchGroupLayouts]);

  useEffect(() => {
    document.documentElement.lang = appLanguage === "zh" ? "zh-CN" : "en";
  }, [appLanguage]);

  async function handlePickApplication() {
    const pickerOptions = await invoke<ApplicationPickerOptions>("application_picker_options");
    const selectedPath = await openDialog({
      title: localizedCopy.selectApplication,
      defaultPath: pickerOptions.defaultPath ?? undefined,
      filters: pickerOptions.filters,
      canCreateDirectories: false,
    });

    if (typeof selectedPath !== "string") {
      return;
    }

    if (
      getRootLaunchEntryCount(launchItems) >=
      getRootLaunchGridCapacity(dockGridSettings)
    ) {
      setLaunchError(localizedCopy.gridFull);
      return;
    }

    try {
      const appInfo = await invoke<ApplicationInfo>("inspect_application", { appPath: selectedPath });

      setLaunchItems((items) => {
        const nextItemId = createId("launch");
        const rootEntryCount = getRootLaunchEntryCount(items);

        if (rootEntryCount >= getRootLaunchGridCapacity(dockGridSettings)) {
          return items;
        }

        const position = getAvailableRootLaunchEntryPosition(
          items,
          getFallbackRootLaunchPosition(rootEntryCount, dockGridSettings),
        );

        if (!position) {
          return items;
        }

        return [
          ...items,
          {
            id: nextItemId,
            name: appInfo.name,
            path: appInfo.path,
            iconDataUrl: appInfo.iconDataUrl ?? undefined,
            group: rootLaunchGroup,
            position,
            createdAt: Date.now(),
          },
        ];
      });
      setLaunchError(null);
    } catch {
      setLaunchError(localizedCopy.invalidAppSelection);
    }
  }

  async function resolveDirectoryInfoForAdd(selectedPath: string): Promise<DirectoryInfo> {
    const selectedInfo = await invoke<DirectoryInfo>("inspect_directory", {
      directoryPath: selectedPath,
    });

    if (
      !directoryItems.some((item) => isSameDirectoryItem(item, selectedInfo)) ||
      !selectedInfo.containingAppDirectoryPath?.trim()
    ) {
      return selectedInfo;
    }

    const containingAppInfo = await invoke<DirectoryInfo>("inspect_directory", {
      directoryPath: selectedInfo.containingAppDirectoryPath,
    });

    return directoryItems.some((item) => isSameDirectoryItem(item, containingAppInfo))
      ? selectedInfo
      : containingAppInfo;
  }

  function getDirectoryItemWithInfo(item: DirectoryItem, directoryInfo: DirectoryInfo): DirectoryItem {
    const iconDataUrl = directoryInfo.iconDataUrl?.trim();

    return {
      ...item,
      comparisonPath: directoryInfo.comparisonPath,
      iconDataUrl: iconDataUrl || item.iconDataUrl,
      name: directoryInfo.name.trim() || item.name,
      path: directoryInfo.path,
    };
  }

  function hasDirectoryInfoChanged(item: DirectoryItem, directoryInfo: DirectoryInfo): boolean {
    const nextItem = getDirectoryItemWithInfo(item, directoryInfo);

    return (
      item.name !== nextItem.name ||
      item.path !== nextItem.path ||
      item.comparisonPath !== nextItem.comparisonPath ||
      item.iconDataUrl !== nextItem.iconDataUrl
    );
  }

  async function handlePickDirectory() {
    const selectedPath = await openDialog({
      title: localizedCopy.selectDirectory,
      directory: true,
      multiple: false,
      canCreateDirectories: true,
    });

    if (typeof selectedPath !== "string") {
      return;
    }

    if (directoryItems.length >= getRootLaunchGridCapacity(dockGridSettings)) {
      setLaunchError(localizedCopy.gridFull);
      return;
    }

    let directoryInfo: DirectoryInfo;

    try {
      directoryInfo = await resolveDirectoryInfoForAdd(selectedPath);
    } catch {
      setLaunchError(localizedCopy.invalidDirectorySelection);
      return;
    }

    const directoryName = directoryInfo.name.trim() || getPathDisplayName(selectedPath);

    const existingDirectoryItem = directoryItems.find((item) =>
      isSameDirectoryItem(item, directoryInfo),
    );

    if (existingDirectoryItem) {
      if (hasDirectoryInfoChanged(existingDirectoryItem, directoryInfo)) {
        setDirectoryItems((items) =>
          normalizeRootDirectoryPositions(
            items.map((item) =>
              item.id === existingDirectoryItem.id
                ? getDirectoryItemWithInfo(item, directoryInfo)
                : item,
            ),
            dockGridSettings,
          ),
        );
        setLaunchError(null);
        return;
      }

      setLaunchError(localizedCopy.directoryAlreadyAdded);
      return;
    }

    if (!directoryName) {
      setLaunchError(localizedCopy.invalidDirectorySelection);
      return;
    }

    setDirectoryItems((items) => {
      const existingItem = items.find((item) => isSameDirectoryItem(item, directoryInfo));

      if (existingItem && hasDirectoryInfoChanged(existingItem, directoryInfo)) {
        return normalizeRootDirectoryPositions(
          items.map((item) =>
            item.id === existingItem.id ? getDirectoryItemWithInfo(item, directoryInfo) : item,
          ),
          dockGridSettings,
        );
      }

      if (
        existingItem ||
        items.length >= getRootLaunchGridCapacity(dockGridSettings)
      ) {
        return items;
      }

      const nextItemId = createId("directory");
      const position = getAvailableDirectoryPosition(
        items,
        getFallbackRootLaunchPosition(items.length, dockGridSettings),
      );

      if (!position) {
        return items;
      }

      return [
        ...items,
        {
          id: nextItemId,
          name: directoryName,
          path: directoryInfo.path,
          comparisonPath: directoryInfo.comparisonPath,
          iconDataUrl: directoryInfo.iconDataUrl?.trim() || undefined,
          position,
          createdAt: Date.now(),
        },
      ];
    });
    setLaunchError(null);
  }

  function updateDockGridSetting(setting: keyof DockGridSettings, value: number) {
    if (!Number.isFinite(value)) {
      return;
    }

    const nextDockGridSettings = normalizeDockGridSettings({
      ...dockGridSettings,
      [setting]: value,
    });

    if (
      nextDockGridSettings.columns === dockGridSettings.columns &&
      nextDockGridSettings.rows === dockGridSettings.rows
    ) {
      setDockGridSettingsError(null);
      return;
    }

    const rootEntryCount = Math.max(getRootLaunchEntryCount(launchItems), directoryItems.length);

    if (rootEntryCount > getRootLaunchGridCapacity(nextDockGridSettings)) {
      setDockGridSettingsError(localizedCopy.dockGridTooSmall);
      return;
    }

    setDockGridSettings(nextDockGridSettings);
    setDockGridSettingsError(null);
    setLaunchItems((items) => normalizeRootLaunchPositions(items, nextDockGridSettings));
    setDirectoryItems((items) => normalizeRootDirectoryPositions(items, nextDockGridSettings));
  }

  async function handleLaunch(item: LaunchItem) {
    try {
      await invoke("launch_application", { appPath: item.path });

      setLaunchError(null);
    } catch {
      setLaunchError(localizedCopy.launchFailed);
    }
  }

  async function handleOpenDirectory(item: DirectoryItem) {
    try {
      await invoke("open_directory", { directoryPath: item.path });

      setLaunchError(null);
    } catch {
      setLaunchError(localizedCopy.openDirectoryFailed);
    }
  }

  async function handleForceShutdown() {
    if (isForceShutdownPending) {
      return;
    }

    setLaunchError(null);

    let confirmed = false;

    try {
      confirmed = await confirmDialog(localizedCopy.forceShutdownConfirmMessage, {
        cancelLabel: localizedCopy.forceShutdownCancel,
        kind: "warning",
        okLabel: localizedCopy.forceShutdownConfirmOk,
        title: localizedCopy.forceShutdownTitle,
      });
    } catch (error) {
      console.error("Failed to open shutdown confirmation dialog", error);
      setLaunchError(localizedCopy.forceShutdownFailed);
      return;
    }

    if (!confirmed) {
      return;
    }

    setIsForceShutdownPending(true);

    try {
      await invoke("request_force_shutdown");
      window.setTimeout(() => setIsForceShutdownPending(false), 15_000);
    } catch (error) {
      console.error("Failed to request forced shutdown", error);
      setIsForceShutdownPending(false);
      setLaunchError(localizedCopy.forceShutdownFailed);
    }
  }

  return (
    <main className="app-shell">
      <aside className="sidebar" aria-label={localizedCopy.appSidebar}>
        <div className="brand-block">
          <img src="/inchspace-icon.svg" className="brand-mark" alt="方寸" />
          <div>
            <strong>方寸</strong>
            <span>InchSpace</span>
          </div>
        </div>

        <nav className="primary-menu" aria-label={localizedCopy.mainMenu}>
          {menuItems.map((item) => {
            const Icon = item.icon;
            const label = item.label[appLanguage];

            return (
              <button
                className={activeMenu === item.id ? "menu-item active" : "menu-item"}
                type="button"
                aria-current={activeMenu === item.id ? "page" : undefined}
                key={item.id}
                onClick={() => setActiveMenu(item.id)}
              >
                <span className="menu-icon">
                  <Icon size={18} strokeWidth={2.2} />
                </span>
                <span className="menu-copy">
                  <strong>{label}</strong>
                </span>
              </button>
            );
          })}
        </nav>

        <div className="sidebar-footer">
          <button className="tool-button" title={localizedCopy.collapseSidebar} type="button">
            <PanelLeft size={18} />
          </button>
        </div>
      </aside>

      <section
        className={["workspace", activeMenu === "dock" ? "workspace-dock" : ""]
          .filter(Boolean)
          .join(" ")}
        aria-label={localizedCopy.workspace}
      >
        {activeMenu === "dock" && (
          <div
            className={[
              "dock-view",
              activeDockTab === "directories" ? "directory-mode" : "program-mode",
              isLaunchEditMode ? "editing" : "",
            ]
              .filter(Boolean)
              .join(" ")}
            ref={dockViewRef}
            onPointerDown={handleDockViewPointerDown}
          >
            {launchError && <p className="workspace-alert">{launchError}</p>}

            <button
              className="shutdown-icon-button"
              type="button"
              aria-label={localizedCopy.forceShutdown}
              title={
                isForceShutdownPending
                  ? localizedCopy.forceShutdownStarting
                  : localizedCopy.forceShutdown
              }
              disabled={isForceShutdownPending}
              onPointerDown={(event) => event.stopPropagation()}
              onClick={() => void handleForceShutdown()}
            >
              <PowerOff size={19} strokeWidth={2.25} aria-hidden="true" />
            </button>

            <div className="dock-view-tabs" role="tablist" aria-label={localizedCopy.workspace}>
              {dockContentTabs.map((tab) => {
                const isActive = activeDockTab === tab.id;
                const TabIcon = tab.id === "programs" ? AppWindow : Folder;

                return (
                  <button
                    className={isActive ? "dock-view-tab active" : "dock-view-tab"}
                    id={`dock-tab-${tab.id}`}
                    role="tab"
                    aria-selected={isActive}
                    aria-controls="dock-panel"
                    type="button"
                    key={tab.id}
                    onClick={(event) => {
                      event.stopPropagation();
                      setActiveDockTab(tab.id);
                    }}
                  >
                    <TabIcon size={15} strokeWidth={2.15} />
                    <span>{tab.label[appLanguage]}</span>
                  </button>
                );
              })}
            </div>

            <div
              className="launch-groups"
              ref={launchGroupsRef}
              style={getLaunchGroupsStyle()}
            >
              <div
                className="launch-root-grid"
                data-launch-root-zone="true"
                ref={launchRootRef}
                role="tabpanel"
                id="dock-panel"
                aria-labelledby={`dock-tab-${activeDockTab}`}
              >
                {activeDockTab === "programs" && (
                  <>
                    {rootLaunchItems.map((item, index) =>
                      renderLaunchApp(item, {
                        rootIndex: index,
                        rootPositioned: true,
                      }),
                    )}

                    {launchGroups.map((group) => renderLaunchGroupFolder(group))}

                    {launchItems.length === 0 && (
                      <div className="empty-state launch-empty-state">
                        <AppWindow size={30} strokeWidth={1.9} />
                        <strong>{localizedCopy.dockEmptyTitle}</strong>
                      </div>
                    )}
                  </>
                )}

                {activeDockTab === "directories" && (
                  <>
                    {sortedDirectoryItems.map((item, index) =>
                      renderDirectoryItem(item, {
                        rootIndex: index,
                        rootPositioned: true,
                      }),
                    )}

                    {directoryItems.length === 0 && (
                      <div className="empty-state launch-empty-state">
                        <Folder size={30} strokeWidth={1.9} />
                        <strong>{localizedCopy.directoryEmptyTitle}</strong>
                      </div>
                    )}
                  </>
                )}
              </div>

              <div className="launch-flow-spacer" aria-hidden="true" />
            </div>

            {activeDockTab === "programs" && renderOpenLaunchGroupPanel()}

            <button
              className="floating-add-button"
              aria-label={activeDockTab === "programs" ? localizedCopy.addApp : localizedCopy.addDirectory}
              title={activeDockTab === "programs" ? localizedCopy.addApp : localizedCopy.addDirectory}
              type="button"
              onClick={() =>
                activeDockTab === "programs"
                  ? void handlePickApplication()
                  : void handlePickDirectory()
              }
            >
              <CircleFadingPlus
                className="floating-add-icon"
                size={26}
                strokeWidth={2.15}
                aria-hidden="true"
              />
            </button>

            {draggedLaunchItem && launchDragState && launchDragState.showDropShadow && (
              <div
                className="launch-drop-shadow"
                style={
                  {
                    left: launchDragState.dropX,
                    top: launchDragState.dropY,
                  } as CSSProperties
                }
                aria-hidden="true"
              />
            )}

            {draggedLaunchGroup && launchGroupDragState && launchGroupDragState.showDropShadow && (
              <div
                className="launch-drop-shadow"
                style={
                  {
                    left: launchGroupDragState.dropX,
                    top: launchGroupDragState.dropY,
                  } as CSSProperties
                }
                aria-hidden="true"
              />
            )}

            {draggedDirectoryItem && directoryDragState && directoryDragState.showDropShadow && (
              <div
                className="launch-drop-shadow"
                style={
                  {
                    left: directoryDragState.dropX,
                    top: directoryDragState.dropY,
                  } as CSSProperties
                }
                aria-hidden="true"
              />
            )}

            {draggedLaunchItem &&
              launchDragState &&
              (() => {
                const [iconStart, iconEnd] = getIconPalette(draggedLaunchItem.name);

                return (
                  <div
                    className="launch-drag-preview"
                    style={
                      {
                        "--launch-drag-preview-scale": launchGroupsScale,
                        left: launchDragState.x,
                        top: launchDragState.y,
                      } as CSSProperties
                    }
                    aria-hidden="true"
                  >
                    <span
                      className={[
                        "launch-app-icon",
                        draggedLaunchItem.iconDataUrl ? "has-custom-icon" : "",
                      ]
                        .filter(Boolean)
                        .join(" ")}
                      style={
                        {
                          "--launch-icon-start": iconStart,
                          "--launch-icon-end": iconEnd,
                        } as CSSProperties
                      }
                    >
                      <span>{getIconLabel(draggedLaunchItem.name)}</span>
                      {draggedLaunchItem.iconDataUrl && (
                        <img src={draggedLaunchItem.iconDataUrl} alt="" draggable={false} />
                      )}
                    </span>
                    <span className="launch-app-delete launch-drag-delete">
                      <X size={14} strokeWidth={2.6} />
                    </span>
                    <span className="launch-app-name">{draggedLaunchItem.name}</span>
                  </div>
                );
              })()}

            {draggedDirectoryItem &&
              directoryDragState && (
                <div
                  className="launch-drag-preview directory-drag-preview"
                  style={
                    {
                      "--launch-drag-preview-scale": launchGroupsScale,
                      left: directoryDragState.x,
                      top: directoryDragState.y,
                    } as CSSProperties
                  }
                  aria-hidden="true"
                >
                  {renderDirectoryIcon(draggedDirectoryItem)}
                  <span className="launch-app-delete launch-drag-delete">
                    <X size={14} strokeWidth={2.6} />
                  </span>
                  <span className="launch-app-name">{draggedDirectoryItem.name}</span>
                </div>
              )}

            {draggedLaunchGroup &&
              launchGroupDragState &&
              (() => {
                const previewItems = getPreviewGroupItems(
                  draggedLaunchGroup.name,
                  draggedLaunchGroup.items,
                );
                const previewLimit = 9;

                return (
                  <div
                    className="launch-drag-preview launch-folder-drag-preview"
                    style={
                      {
                        "--launch-drag-preview-scale": launchGroupsScale,
                        left: launchGroupDragState.x,
                        top: launchGroupDragState.y,
                      } as CSSProperties
                    }
                    aria-hidden="true"
                  >
                    <span className="launch-folder-icon">
                      {Array.from({ length: previewLimit }, (_, index) => {
                        const item = previewItems[index];

                        return item
                          ? renderLaunchFolderThumbnail(item)
                          : <span className="launch-folder-mini-empty" key={index} />;
                      })}
                    </span>
                    <span className="launch-app-name">{draggedLaunchGroup.displayName}</span>
                  </div>
                );
              })()}
          </div>
        )}

        {activeMenu === "settings" && (
          <div className="settings-view">
            {dockGridSettingsError && <p className="workspace-alert">{dockGridSettingsError}</p>}

            <section className="settings-list" aria-label={menuItems[1].label[appLanguage]}>
              <div className="settings-row">
                <div className="setting-label">
                  <span className="setting-icon" aria-hidden="true">
                    <Languages size={18} strokeWidth={2.2} />
                  </span>
                  <strong>{localizedCopy.languageSetting}</strong>
                </div>

                <div className="language-select-wrap">
                  <select
                    className="language-select"
                    aria-label={localizedCopy.languageSelector}
                    value={languagePreference}
                    onChange={(event) => {
                      const nextPreference = event.currentTarget.value;

                      if (isLanguagePreference(nextPreference)) {
                        setLanguagePreference(nextPreference);
                      }
                    }}
                  >
                    <option value="system">{localizedCopy.followSystem}</option>
                    {availableLanguages.map((language) => (
                      <option lang={language.htmlLang} value={language.value} key={language.value}>
                        {language.label}
                      </option>
                    ))}
                  </select>
                </div>
              </div>

              <div className="settings-row">
                <div className="setting-label">
                  <span className="setting-icon" aria-hidden="true">
                    <Dock size={18} strokeWidth={2.2} />
                  </span>
                  <strong>{localizedCopy.dockIconVisibilitySetting}</strong>
                </div>

                <label className="switch-control">
                  <input
                    type="checkbox"
                    role="switch"
                    checked={dockIconVisible}
                    aria-label={localizedCopy.dockIconVisibilityToggle}
                    onChange={(event) => setDockIconVisible(event.currentTarget.checked)}
                  />
                  <span className="switch-track" aria-hidden="true">
                    <span className="switch-thumb" />
                  </span>
                  <span className="switch-value">
                    {dockIconVisible ? localizedCopy.dockIconVisible : localizedCopy.dockIconHidden}
                  </span>
                </label>
              </div>

              <div className="settings-row">
                <div className="setting-label">
                  <span className="setting-icon" aria-hidden="true">
                    <AppWindow size={18} strokeWidth={2.2} />
                  </span>
                  <strong>{localizedCopy.floatingBallStyleSetting}</strong>
                </div>

                <div className="floating-ball-style-options" role="radiogroup" aria-label={localizedCopy.floatingBallStyleSetting}>
                  {floatingBallStyleOptions.map((option) => {
                    const isActive = floatingBallStyle === option.value;

                    return (
                      <button
                        className={isActive ? "floating-ball-style-option active" : "floating-ball-style-option"}
                        type="button"
                        role="radio"
                        aria-checked={isActive}
                        key={option.value}
                        onClick={() => setFloatingBallStyle(option.value)}
                      >
                        <span className="floating-ball-style-preview" aria-hidden="true">
                          <FloatingBallVisual
                            floatingBallStyle={option.value}
                            isPreview
                            metricsHistory={previewMetricsHistory}
                          />
                        </span>
                        <span>{option.label[appLanguage]}</span>
                      </button>
                    );
                  })}
                </div>
              </div>

              <div className="settings-row">
                <div className="setting-label">
                  <span className="setting-icon" aria-hidden="true">
                    <LayoutGrid size={18} strokeWidth={2.2} />
                  </span>
                  <strong>{localizedCopy.dockLayoutSetting}</strong>
                </div>

                <div className="dock-grid-settings" aria-label={localizedCopy.dockLayoutSetting}>
                  <label className="number-field">
                    <span>{localizedCopy.dockColumns}</span>
                    <input
                      className="number-input"
                      type="number"
                      min={dockGridColumnRange.min}
                      max={dockGridColumnRange.max}
                      step={1}
                      value={dockGridSettings.columns}
                      onChange={(event) =>
                        updateDockGridSetting("columns", event.currentTarget.valueAsNumber)
                      }
                    />
                  </label>

                  <label className="number-field">
                    <span>{localizedCopy.dockRows}</span>
                    <input
                      className="number-input"
                      type="number"
                      min={dockGridRowRange.min}
                      max={dockGridRowRange.max}
                      step={1}
                      value={dockGridSettings.rows}
                      onChange={(event) =>
                        updateDockGridSetting("rows", event.currentTarget.valueAsNumber)
                      }
                    />
                  </label>
                </div>
              </div>
            </section>
          </div>
        )}
      </section>
    </main>
  );
}

function App() {
  const currentWindowLabel = getCurrentWindowLabel();

  syncDocumentWindowLabel(currentWindowLabel);
  syncDocumentPlatform();

  useEffect(() => {
    syncDocumentWindowLabel(currentWindowLabel);
    syncDocumentPlatform();
  }, [currentWindowLabel]);

  return currentWindowLabel === floatingBallWindowLabel ? <FloatingBallApp /> : <MainApp />;
}

export default App;
