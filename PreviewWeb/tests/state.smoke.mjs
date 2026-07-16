import assert from "node:assert/strict";
import {
  deriveProgress,
  initialState,
  normalizeState,
  reduceState,
  replanSummary,
} from "../core.mjs";

let state = normalizeState(initialState);
assert.equal(state.route, "today");
assert.equal(state.layout, "auto");

state = reduceState(state, { type: "SET_LAYOUT", layout: "phone" });
assert.equal(state.layout, "phone", "iPhone compact mode must be selectable");

state = reduceState(state, { type: "START_GUIDED" });
assert.equal(state.route, "guided", "Today action must open Guided Learning");

state = reduceState(state, { type: "SET_GUIDED_STEP", step: 2 });
state = reduceState(state, { type: "ANSWER_QUIZ", answer: "b" });
assert.equal(state.quizAnswer, "b", "Quiz selection must be retained");

const beforeProgress = deriveProgress(state);
state = reduceState(state, { type: "COMPLETE_TASK" });
const afterProgress = deriveProgress(state);
assert.equal(state.route, "today", "Completing a task must return to Today");
assert.equal(state.taskCompleted, true);
assert.ok(afterProgress.ultimateGoal > beforeProgress.ultimateGoal, "Completion must update goal progress");

state = reduceState(state, { type: "APPLY_REPLAN", minutes: 10 });
assert.equal(state.replanApplied, true);
assert.equal(state.availableMinutes, 10);
assert.equal(replanSummary(10).duration, 10);

state = reduceState(state, { type: "NAVIGATE", route: "paper" });
assert.equal(state.route, "paper", "Paper Reader must be navigable");
state = reduceState(state, { type: "NAVIGATE", route: "goals" });
assert.equal(state.route, "goals", "Goals must be navigable");
state = reduceState(state, { type: "NAVIGATE", route: "workspace" });
state = reduceState(state, { type: "SELECT_WORKSPACE", workspace: "career" });
assert.equal(state.workspace, "career", "Workspace modes must be selectable");

const normalizedInvalid = normalizeState({ route: "unknown", layout: "watch", availableMinutes: 99 });
assert.equal(normalizedInvalid.route, "today");
assert.equal(normalizedInvalid.layout, "auto");
assert.equal(normalizedInvalid.availableMinutes, 20);

console.log("State smoke tests passed: Today → Guided → completion → replan → sources/goals/workspace.");
