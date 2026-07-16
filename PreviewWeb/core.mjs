export const STORAGE_KEY = "nextstep-contract-preview-v1";

export const routeTitles = Object.freeze({
  today: "Today",
  guided: "引導式學習",
  paper: "來源閱讀",
  goals: "目標與里程碑",
  workspace: "工作區",
});

export const initialState = Object.freeze({
  version: 1,
  route: "today",
  layout: "auto",
  theme: "light",
  guidedStep: 0,
  taskCompleted: false,
  replanApplied: false,
  availableMinutes: 20,
  quizAnswer: null,
  workspace: "thesis",
  selectedHighlight: "yellow",
});

const validRoutes = new Set(Object.keys(routeTitles));
const validLayouts = new Set(["auto", "phone", "tablet"]);
const validThemes = new Set(["light", "dark"]);
const validWorkspaces = new Set(["thesis", "project", "career"]);
const validHighlights = new Set(["yellow", "blue", "green", "orange", "purple"]);

export function normalizeState(candidate = {}) {
  const state = { ...initialState, ...(candidate && typeof candidate === "object" ? candidate : {}) };
  state.version = 1;
  state.route = validRoutes.has(state.route) ? state.route : initialState.route;
  state.layout = validLayouts.has(state.layout) ? state.layout : initialState.layout;
  state.theme = validThemes.has(state.theme) ? state.theme : initialState.theme;
  state.guidedStep = clampInteger(state.guidedStep, 0, 3, 0);
  state.taskCompleted = Boolean(state.taskCompleted);
  state.replanApplied = Boolean(state.replanApplied);
  state.availableMinutes = [10, 20, 35].includes(Number(state.availableMinutes)) ? Number(state.availableMinutes) : 20;
  state.quizAnswer = ["a", "b", "c"].includes(state.quizAnswer) ? state.quizAnswer : null;
  state.workspace = validWorkspaces.has(state.workspace) ? state.workspace : initialState.workspace;
  state.selectedHighlight = validHighlights.has(state.selectedHighlight) ? state.selectedHighlight : initialState.selectedHighlight;
  return state;
}

export function reduceState(current, action) {
  const state = normalizeState(current);
  if (!action || typeof action.type !== "string") return state;

  switch (action.type) {
    case "NAVIGATE":
      return validRoutes.has(action.route) ? { ...state, route: action.route } : state;
    case "SET_LAYOUT":
      return validLayouts.has(action.layout) ? { ...state, layout: action.layout } : state;
    case "TOGGLE_THEME":
      return { ...state, theme: state.theme === "dark" ? "light" : "dark" };
    case "START_GUIDED":
      return { ...state, route: "guided", guidedStep: state.taskCompleted ? 3 : 0 };
    case "SET_GUIDED_STEP":
      return { ...state, guidedStep: clampInteger(action.step, 0, 3, state.guidedStep) };
    case "ANSWER_QUIZ":
      return ["a", "b", "c"].includes(action.answer) ? { ...state, quizAnswer: action.answer } : state;
    case "COMPLETE_TASK":
      return { ...state, taskCompleted: true, guidedStep: 3, route: "today" };
    case "APPLY_REPLAN":
      return {
        ...state,
        replanApplied: true,
        availableMinutes: [10, 20, 35].includes(Number(action.minutes)) ? Number(action.minutes) : state.availableMinutes,
        route: "today",
      };
    case "SELECT_WORKSPACE":
      return validWorkspaces.has(action.workspace) ? { ...state, workspace: action.workspace } : state;
    case "SELECT_HIGHLIGHT":
      return validHighlights.has(action.highlight) ? { ...state, selectedHighlight: action.highlight } : state;
    case "RESET":
      return { ...initialState, layout: state.layout, theme: state.theme };
    default:
      return state;
  }
}

export function deriveProgress(state) {
  const normalized = normalizeState(state);
  return {
    ultimateGoal: normalized.taskCompleted ? 35 : 34,
    milestone: normalized.taskCompleted ? 69 : 64,
    todayCompleted: normalized.taskCompleted ? 2 : 1,
    todayTotal: normalized.replanApplied ? 2 : 3,
  };
}

export function replanSummary(minutes) {
  switch (Number(minutes)) {
    case 10:
      return { duration: 10, requiredOutput: "寫下 2 句因果關係", deferred: "來源比較與延伸測驗" };
    case 35:
      return { duration: 35, requiredOutput: "完成概念卡與 3 題測驗", deferred: "只延後間隔複習" };
    default:
      return { duration: 20, requiredOutput: "完成概念卡與 1 題檢核", deferred: "3 題延伸練習" };
  }
}

function clampInteger(value, min, max, fallback) {
  const number = Number(value);
  if (!Number.isInteger(number)) return fallback;
  return Math.min(max, Math.max(min, number));
}
