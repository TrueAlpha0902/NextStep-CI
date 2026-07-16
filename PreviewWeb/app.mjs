import {
  STORAGE_KEY,
  deriveProgress,
  initialState,
  normalizeState,
  reduceState,
  replanSummary,
  routeTitles,
} from "./core.mjs";

const content = document.querySelector("#preview-content");
const stage = document.querySelector("#device-stage");
const shell = document.querySelector(".app-shell");
const routeTitle = document.querySelector("#route-title");
const deviceName = document.querySelector("#device-name");
const dimensionMark = document.querySelector("#dimension-mark");
const themeToggle = document.querySelector("#theme-toggle");
const resetButton = document.querySelector("#reset-demo");
const replanDialog = document.querySelector("#replan-dialog");
const applyReplanButton = document.querySelector("#apply-replan");
const proposalDuration = document.querySelector("#proposal-duration");
const toast = document.querySelector("#toast");

let state = loadState();
let toastTimer = null;

applyStateToChrome();
render();

document.addEventListener("click", (event) => {
  const layoutButton = event.target.closest("[data-layout]");
  if (layoutButton) {
    dispatch({ type: "SET_LAYOUT", layout: layoutButton.dataset.layout });
    return;
  }

  const routeButton = event.target.closest("[data-route]");
  if (routeButton) {
    dispatch({ type: "NAVIGATE", route: routeButton.dataset.route });
    focusContent();
    return;
  }

  const actionButton = event.target.closest("[data-action]");
  if (actionButton) {
    performAction(actionButton.dataset.action);
    return;
  }

  const stepButton = event.target.closest("[data-step]");
  if (stepButton) {
    dispatch({ type: "SET_GUIDED_STEP", step: Number(stepButton.dataset.step) });
    return;
  }

  const answerButton = event.target.closest("[data-answer]");
  if (answerButton) {
    dispatch({ type: "ANSWER_QUIZ", answer: answerButton.dataset.answer });
    return;
  }

  const workspaceButton = event.target.closest("[data-workspace]");
  if (workspaceButton) {
    dispatch({ type: "SELECT_WORKSPACE", workspace: workspaceButton.dataset.workspace });
    return;
  }

  const highlightButton = event.target.closest("[data-highlight]");
  if (highlightButton) {
    dispatch({ type: "SELECT_HIGHLIGHT", highlight: highlightButton.dataset.highlight });
  }
});

themeToggle.addEventListener("click", () => {
  dispatch({ type: "TOGGLE_THEME" });
});

resetButton.addEventListener("click", () => {
  dispatch({ type: "RESET" });
  showToast("示範狀態已重設；裝置與明暗偏好保留。 ");
});

document.querySelectorAll('input[name="available-time"]').forEach((radio) => {
  radio.addEventListener("change", () => {
    const summary = replanSummary(Number(radio.value));
    proposalDuration.textContent = `${summary.duration} 分鐘`;
  });
});

applyReplanButton.addEventListener("click", () => {
  const selected = document.querySelector('input[name="available-time"]:checked');
  const minutes = selected ? Number(selected.value) : 20;
  dispatch({ type: "APPLY_REPLAN", minutes });
  replanDialog.close();
  const summary = replanSummary(minutes);
  showToast(`已套用 ${minutes} 分鐘方案：${summary.deferred}移到之後。`);
});

const resizeObserver = new ResizeObserver(() => applyResponsiveMode());
resizeObserver.observe(document.querySelector("#device-frame"));

function dispatch(action) {
  state = reduceState(state, action);
  persistState();
  applyStateToChrome();
  render();
}

function loadState() {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored ? normalizeState(JSON.parse(stored)) : { ...initialState };
  } catch {
    return { ...initialState };
  }
}

function persistState() {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch {
    // The preview remains fully usable when storage is unavailable.
  }
}

function applyStateToChrome() {
  document.documentElement.dataset.theme = state.theme;
  stage.className = `device-stage ${state.layout}`;
  shell.classList.remove("compact");

  document.querySelectorAll("[data-layout]").forEach((button) => {
    button.setAttribute("aria-pressed", String(button.dataset.layout === state.layout));
  });

  themeToggle.setAttribute("aria-label", state.theme === "dark" ? "切換淺色模式" : "切換深色模式");
  routeTitle.textContent = routeTitles[state.route];

  const navRoute = state.route === "guided" ? "today" : state.route;
  document.querySelectorAll("[data-route]").forEach((button) => {
    if (!button.closest(".side-nav, .bottom-nav")) return;
    if (button.dataset.route === navRoute) button.setAttribute("aria-current", "page");
    else button.removeAttribute("aria-current");
  });

  const labels = {
    auto: ["Responsive auto", "依容器自動切換 compact / regular"],
    phone: ["iPhone compact", "390 pt compact contract"],
    tablet: ["iPad regular", "Regular width contract"],
  };
  deviceName.textContent = labels[state.layout][0];
  dimensionMark.textContent = labels[state.layout][1];
  applyResponsiveMode();
}

function applyResponsiveMode() {
  if (state.layout !== "auto") {
    shell.classList.remove("compact");
    return;
  }
  shell.classList.toggle("compact", document.querySelector("#device-frame").clientWidth < 760);
}

function render() {
  const renderers = {
    today: renderToday,
    guided: renderGuided,
    paper: renderPaper,
    goals: renderGoals,
    workspace: renderWorkspace,
  };
  content.innerHTML = renderers[state.route]();
  content.scrollTop = 0;
}

function renderToday() {
  const progress = deriveProgress(state);
  const summary = replanSummary(state.availableMinutes);
  const taskCard = state.taskCompleted
    ? `
      <article class="action-card completed">
        <div class="card-meta"><span>必須完成</span><span>•</span><span>已完成 14:32</span></div>
        <div class="completion-mark">今日核心行動完成</div>
        <h2>理解負債如何影響 WACC</h2>
        <p>已儲存概念卡、測驗結果與來源錨點；Milestone 進度已更新。</p>
        <div class="action-card-footer">
          <span class="badge confirmed">使用者確認完成</span>
          <button class="secondary-button" type="button" data-action="start-guided">查看成果</button>
        </div>
      </article>`
    : `
      <article class="action-card">
        <div class="badge-row">
          <span class="badge confirmed">必須完成</span>
          <span class="badge verified">2 個已驗證來源</span>
          <span class="badge ai">AI 建議 · 可檢查</span>
        </div>
        <div class="card-meta"><span>${state.replanApplied ? summary.duration : 35} 分鐘</span><span>•</span><span>中等</span><span>•</span><span>建議 15:00 前開始</span></div>
        <h2>理解負債如何影響 WACC</h2>
        <p>閱讀指定範圍、辨認負債成本的作用，最後完成一張可複習的概念卡。</p>
        <div class="why-line">
          <strong>Why today</strong>
          <span>週五作業會用到這個概念；先完成能降低明天撰寫分析段落的阻塞。</span>
        </div>
        <div class="prepared-materials" aria-label="系統已準備材料">
          <span>5 分鐘前置概念</span><span>必讀 2 段</span><span>來源錨點</span><span>${state.replanApplied ? "1" : "3"} 題理解檢核</span>
        </div>
        <div class="action-card-footer">
          <span class="card-meta">推進：企業財務能力 → WACC 分析</span>
          <button class="primary-button" type="button" data-action="start-guided">開始引導任務</button>
        </div>
      </article>`;

  const secondaryTask = state.replanApplied
    ? `
      <article class="action-card completed">
        <div class="card-meta"><span>已重新安排</span><span>•</span><span>移到明天</span></div>
        <h3>${summary.deferred}</h3>
        <p>確定的作業截止日未變；這項彈性行動保留原始規劃紀錄。</p>
      </article>`
    : `
      <article class="action-card">
        <div class="card-meta"><span>建議完成</span><span>•</span><span>20 分鐘</span></div>
        <h3>比較兩種資本結構情境</h3>
        <p>用範例數值寫下兩句比較，為明天的分析段落準備證據。</p>
      </article>`;

  return `
    <section class="screen today-screen" aria-labelledby="today-title">
      <header class="screen-heading">
        <div>
          <span class="eyebrow">Good morning · 今日執行面</span>
          <h1 id="today-title">今天先完成這一步。</h1>
          <p>材料已準備好，你不需要再決定先找什麼。</p>
        </div>
        <div class="date-block"><span>WED</span><strong>7 月 15 日</strong></div>
      </header>

      <section class="goal-progress-header" aria-label="最終目標進度">
        <div class="progress-ring" style="--value:${progress.ultimateGoal}" data-label="${progress.ultimateGoal}%" aria-label="最終目標進度 ${progress.ultimateGoal}%"></div>
        <div class="goal-progress-copy">
          <span>Ultimate Goal · 2028</span>
          <strong>完成研究所並取得企業金融職位</strong>
          <span>目前 Milestone：建立可驗證的財務分析能力 · ${progress.milestone}%</span>
        </div>
        <div class="risk-status"><strong>在安全範圍</strong><span>距風險門檻 3 天</span></div>
      </section>

      <div class="today-grid">
        <div class="section-stack">
          <div class="section-label"><h2>現在要做</h2><span>${progress.todayCompleted} / ${progress.todayTotal} 已完成</span></div>
          ${taskCard}
          <div class="section-label"><h2>${state.replanApplied ? "已調整" : "接著做"}</h2><span>${state.replanApplied ? "保留規劃理由" : "完成核心後再開始"}</span></div>
          ${secondaryTask}
        </div>

        <aside class="side-panel" aria-label="今日摘要">
          <section class="info-card">
            <h3>今日負荷</h3>
            <div class="time-summary"><strong>${state.replanApplied ? state.availableMinutes : 70} 分</strong><span>${state.replanApplied ? "已依可用時間調整" : "2 個專注區段"}</span></div>
            <div class="linear-progress" aria-label="今日已完成 ${progress.todayCompleted} 個任務"><span style="width:${Math.round(progress.todayCompleted / progress.todayTotal * 100)}%"></span></div>
          </section>
          <section class="info-card">
            <h3>與行程對齊</h3>
            <ul class="schedule-list">
              <li><time>13:30</time><span>企業財務課程</span></li>
              <li><time>15:00</time><span>建議專注區段</span></li>
              <li><time>18:00</time><span>固定休息，不排任務</span></li>
            </ul>
          </section>
          <section class="info-card replan-card">
            <h3>今天不如預期？</h3>
            ${state.replanApplied
              ? `<div class="replan-result"><strong>已重新安排</strong><span>${state.availableMinutes} 分鐘內保留必要產出；明確截止日沒有變。</span></div>`
              : `<p>告訴系統剩餘時間，先看變更提案，再決定是否套用。</p>`}
            <button class="secondary-button" type="button" data-action="open-replan">${state.replanApplied ? "再次調整" : "我今天時間不足"}</button>
          </section>
        </aside>
      </div>
    </section>`;
}

function renderGuided() {
  const stepNames = ["先備概念", "指定閱讀", "理解檢核", "完成產出"];
  const stepButtons = stepNames.map((name, index) => `
    <button type="button" data-step="${index}" ${state.guidedStep === index ? 'aria-current="step"' : ""}>
      <span class="step-number">${index + 1}</span><span>${name}</span>
    </button>`).join("");

  return `
    <section class="screen guided-screen" aria-labelledby="guided-title">
      <nav class="breadcrumb" aria-label="麵包屑">
        <button type="button" data-route="today">Today</button><span>／</span><span>企業財務能力</span><span>／</span><span aria-current="page">WACC</span>
      </nav>
      <header class="guided-header">
        <div>
          <span class="eyebrow">Guided Learning Package · 來源可追溯</span>
          <h1 id="guided-title">理解負債如何影響 WACC</h1>
          <p>學習目標：能用自己的話說明負債成本、稅盾與資本結構的關係。</p>
        </div>
        <div class="timer-block"><span>預估剩餘</span><strong>${[30, 21, 10, 4][state.guidedStep]}:00</strong></div>
      </header>

      <div class="guided-grid">
        <nav class="step-rail" aria-label="學習步驟">${stepButtons}</nav>
        <article class="learning-stage">${renderGuidedStage()}</article>
        <aside class="source-inspector" aria-label="來源與完成標準">
          <section class="source-card">
            <div class="badge-row"><span class="badge verified">來源已驗證</span><span class="badge">Fixture</span></div>
            <h3>NextStep Finance Source Fixture</h3>
            <p>本機合約示範文件 · v1.0。內容只用於介面與來源錨點測試。</p>
            <small>必讀：第 12 頁，第 3–4 段</small>
            <button class="text-button" type="button" data-action="open-paper">查看原文與定位 →</button>
          </section>
          <section class="why-block">
            <h3>今天為什麼安排</h3>
            <p>這是週五作業的依賴概念；若延後，明天的分析段落將沒有可引用的因果架構。</p>
          </section>
          <section class="criteria-block">
            <h3>完成標準</h3>
            <ul class="check-list">
              <li class="${state.guidedStep > 0 ? "done" : ""}">讀完兩個來源錨點</li>
              <li class="${state.quizAnswer === "b" ? "done" : ""}">答對核心理解題</li>
              <li class="${state.taskCompleted || state.guidedStep === 3 ? "done" : ""}">完成一張概念卡</li>
            </ul>
          </section>
        </aside>
      </div>
    </section>`;
}

function renderGuidedStage() {
  const stages = [renderPrerequisite, renderReading, renderQuiz, renderOutput];
  return stages[state.guidedStep]();
}

function renderPrerequisite() {
  return `
    <span class="eyebrow">Step 1 · 5 minutes</span>
    <h2>先建立一個可用的心智模型</h2>
    <p>WACC 是公司取得各種資金的加權平均成本。今天只聚焦負債這一部分。</p>
    <div class="concept-note">
      <strong>先記住兩件事</strong>
      <span class="formula-line">WACC = E/V × Rₑ + D/V × Rᵈ × (1 − T)</span>
      <p>負債比例上升會改變權重；稅盾會降低稅後負債成本，但風險也可能使資金成本上升。</p>
    </div>
    <div class="guided-callout"><strong>引導問題</strong><span>為什麼「負債比較便宜」不代表公司應該無限增加負債？先保留你的直覺，讀完後再回答。</span></div>
    <div class="step-actions"><span></span><button class="primary-button" type="button" data-action="next-step">下一步：指定閱讀</button></div>`;
}

function renderReading() {
  return `
    <span class="eyebrow">Step 2 · Source anchored</span>
    <h2>只讀已指定的兩段</h2>
    <p>不需要從頭讀整份文件。先讀第 12 頁第 3 段，再讀第 4 段的限制。</p>
    <div class="concept-note">
      <span class="badge verified">Anchor · p.12 ¶3</span>
      <p><mark class="highlighted-passage">示範段落說明稅後負債成本如何進入加權公式，以及權重變動會如何改變結果。</mark></p>
      <span class="badge verified">Anchor · p.12 ¶4</span>
      <p><mark class="highlighted-passage blue">示範段落補充：當財務風險改變時，不能只固定其他參數再外推結論。</mark></p>
    </div>
    <div class="guided-callout"><strong>閱讀時要找</strong><span>標出一個「降低成本」的機制，以及一個「限制無限加債」的機制。</span></div>
    <div class="step-actions"><button class="secondary-button" type="button" data-action="open-paper">在來源閱讀器開啟</button><button class="primary-button" type="button" data-action="next-step">我讀完了</button></div>`;
}

function renderQuiz() {
  const feedback = state.quizAnswer
    ? state.quizAnswer === "b"
      ? `<div class="quiz-feedback"><strong>正確。</strong> 稅盾降低稅後負債成本，但資本結構改變也可能提高風險與其他資金成本。</div>`
      : `<div class="quiz-feedback"><strong>再想一次。</strong> 回到公式，分別檢查稅後成本、權重與風險是否都保持不變。</div>`
    : "";
  return `
    <span class="eyebrow">Step 3 · Understanding check</span>
    <h2>哪個說法最完整？</h2>
    <p>這題檢查你是否把「成本較低」錯誤推論成「越多越好」。</p>
    <div class="quiz-options">
      <button type="button" data-answer="a" class="${state.quizAnswer === "a" ? "selected" : ""}">A. 增加負債一定會持續降低 WACC</button>
      <button type="button" data-answer="b" class="${state.quizAnswer === "b" ? "selected" : ""}">B. 稅盾可能降低成本，但仍要一起評估權重與風險變化</button>
      <button type="button" data-answer="c" class="${state.quizAnswer === "c" ? "selected" : ""}">C. 負債成本不會受到公司風險影響</button>
    </div>
    ${feedback}
    <div class="step-actions"><button class="secondary-button" type="button" data-action="previous-step">回來源</button><button class="primary-button" type="button" data-action="next-step" ${state.quizAnswer !== "b" ? "disabled" : ""}>建立完成產出</button></div>`;
}

function renderOutput() {
  return `
    <span class="eyebrow">Step 4 · Required output</span>
    <h2>完成一張 WACC 因果概念卡</h2>
    <p>不是抄摘要。請用三個欄位留下未來能直接複習與引用的產出。</p>
    <div class="concept-note">
      <strong>概念卡預覽</strong>
      <p><b>機制：</b>稅盾使負債的稅後成本下降。</p>
      <p><b>限制：</b>槓桿上升可能改變財務風險，不能假設其他成本固定。</p>
      <p><b>來源：</b>Fixture p.12 ¶3–4；每個句子保留來源錨點。</p>
    </div>
    <div class="guided-callout"><strong>下一步</strong><span>明天把這張卡用在「比較兩種資本結構情境」的分析段落。</span></div>
    <div class="step-actions"><button class="secondary-button" type="button" data-action="previous-step">回理解題</button><button class="primary-button" type="button" data-action="complete-task">${state.taskCompleted ? "已完成 · 回 Today" : "確認產出並完成"}</button></div>`;
}

function renderPaper() {
  const highlightDescriptions = {
    yellow: ["核心結論", "必須記住的內容"],
    blue: ["定義／方法", "公式、研究方法與重要數據"],
    green: ["案例應用", "案例、應用與實務影響"],
    orange: ["限制風險", "限制、風險、反例與爭議"],
    purple: ["知識連結", "與既有筆記或目標的連結"],
  };
  const selected = highlightDescriptions[state.selectedHighlight];
  return `
    <section class="screen paper-screen" aria-labelledby="paper-title">
      <div class="reader-shell">
        <div class="reader-main">
          <header class="reader-toolbar">
            <div><span class="eyebrow">Source Reader · Contract fixture</span><h1 id="paper-title">負債成本與資本結構</h1></div>
            <span class="page-indicator">12 / 24</span>
          </header>
          <article class="paper-page" aria-label="示範來源第 12 頁">
            <h2>3. Debt cost in the weighted model</h2>
            <div class="paper-byline">NextStep Product Fixture · version 1.0 · 非真實論文</div>
            <p>這份合約測試資料用來展示來源定位。<mark class="highlighted-passage">稅後負債成本在加權模型中同時受到成本、稅率與資本權重影響。</mark> 因此，每個摘要句都必須回到原始文件的可識別位置。</p>
            <p>在示範情境中，負債占比變動會改變權重。<mark class="highlighted-passage blue">若同時發生風險變化，就不能把其他資金成本視為永久固定。</mark> 這是解讀模型時應明確揭露的限制。</p>
            <aside class="margin-note">AI 解釋（可檢查）：黃色句是核心機制；藍色句是模型限制。兩者分別連到下方 Evidence Link。</aside>
            <p>本頁文字是 NextStep 自有的測試內容，不代表任何外部研究結論。正式 App 必須顯示作者、出版資訊、DOI、合法全文狀態與存取日期；找不到全文時只能標示摘要可用。</p>
          </article>
        </div>

        <aside class="reader-inspector" aria-label="來源檢查器">
          <span class="eyebrow">Source transparency</span>
          <h2>來源與證據</h2>
          <div class="badge-row"><span class="badge verified">本機文件已驗證</span><span class="badge ai">AI 摘要</span></div>
          <div class="source-facts">
            <div class="source-fact"><span>來源類型</span><strong>產品測試 fixture</strong></div>
            <div class="source-fact"><span>作者</span><strong>NextStep Product Team</strong></div>
            <div class="source-fact"><span>版本</span><strong>1.0 · 2026</strong></div>
            <div class="source-fact"><span>DOI</span><strong>不適用</strong></div>
            <div class="source-fact"><span>全文狀態</span><strong>本機完整內容</strong></div>
          </div>
          <button type="button" class="secondary-button" data-action="source-demo">原始檔案行為預覽</button>

          <div class="section-label"><h3>螢光語意</h3><span>不只靠顏色</span></div>
          <div class="highlight-legend" aria-label="螢光標記語意">
            ${Object.keys(highlightDescriptions).map((key) => `<button type="button" class="${key}" data-highlight="${key}" aria-label="${highlightDescriptions[key][0]}" aria-pressed="${state.selectedHighlight === key}"></button>`).join("")}
          </div>
          <div class="claim-card">
            <span>目前標記 · ${selected[0]}</span>
            <strong>${selected[1]}</strong>
            <small>每個標記同時保存類型文字、頁碼、文字範圍與原始內容。</small>
          </div>
          <div class="claim-card">
            <span>Extracted Claim C-014</span>
            <strong>稅後負債成本影響加權結果</strong>
            <small>Evidence Link → Source Anchor p.12 ¶3 · confidence 0.96</small>
          </div>
          <div class="claim-card">
            <span>Limitation L-007</span>
            <strong>不能固定所有風險參數後無限外推</strong>
            <small>Evidence Link → Source Anchor p.12 ¶4 · user review required</small>
          </div>
        </aside>
      </div>
    </section>`;
}

function renderGoals() {
  const progress = deriveProgress(state);
  return `
    <section class="screen goals-screen" aria-labelledby="goals-title">
      <header class="screen-heading">
        <div><span class="eyebrow">Goal hierarchy · Facts stay immutable</span><h1 id="goals-title">目標不是清單，而是一條因果鏈。</h1><p>每個 Today 行動都能回溯到 Milestone 與最終目標。</p></div>
      </header>
      <section class="goal-hero">
        <div>
          <span class="eyebrow">Ultimate Goal · 使用者確認</span>
          <h2>2028 年完成研究所，取得企業金融相關職位</h2>
          <p>截止日期與畢業要求是已確認事實，系統不會自行修改。可彈性調整的是通往成果的每日行動。</p>
          <div class="badge-row"><span class="badge confirmed">使用者確認</span><span class="badge verified">2 個規則來源</span></div>
        </div>
        <div class="goal-metric"><span>整體進度</span><strong>${progress.ultimateGoal}%</strong><div class="linear-progress"><span style="width:${progress.ultimateGoal}%"></span></div><small>預估仍在計畫範圍</small></div>
      </section>
      <div class="section-label"><h2>目前 Goal · 建立求職所需財務分析能力</h2><span>4 個 Milestone</span></div>
      <div class="milestone-timeline" aria-label="里程碑時間軸">
        <article class="milestone-row done"><time class="milestone-date">6 月 30 日</time><div class="milestone-axis"><span class="milestone-dot">✓</span></div><div class="milestone-copy"><h3>建立企業財務基礎概念圖</h3><p>已完成 18 個概念與 31 個來源連結。</p></div><span class="milestone-status">已完成</span></article>
        <article class="milestone-row current"><time class="milestone-date">7 月 25 日</time><div class="milestone-axis"><span class="milestone-dot"></span></div><div class="milestone-copy"><h3>能分析資本結構與 WACC</h3><p>本週成果：完成概念卡、情境比較與一段可引用分析。</p><div class="linear-progress"><span style="width:${progress.milestone}%"></span></div></div><span class="milestone-status">${progress.milestone}% · 進行中</span></article>
        <article class="milestone-row"><time class="milestone-date">8 月 18 日</time><div class="milestone-axis"><span class="milestone-dot">3</span></div><div class="milestone-copy"><h3>完成一份公司財務分析</h3><p>依賴：WACC 分析、估值假設與來源審查。</p></div><span class="milestone-status">尚未開始</span></article>
        <article class="milestone-row"><time class="milestone-date">9 月 10 日</time><div class="milestone-axis"><span class="milestone-dot">4</span></div><div class="milestone-copy"><h3>轉為作品集與履歷證據</h3><p>產出可公開的 Case Study 與能力敘述。</p></div><span class="milestone-status">尚未開始</span></article>
      </div>
    </section>`;
}

function renderWorkspace() {
  const workspaces = {
    thesis: {
      eyebrow: "Thesis workspace",
      title: "論文研究：金融科技採用行為",
      description: "從研究問題、文獻證據到章節產出，都保留來源與決策脈絡。",
      outputs: [
        ["研究背景第一段", "3 個證據點已備妥", "今天"],
        ["文獻比較表", "6 / 10 篇已篩選", "進行中"],
        ["候選研究問題", "等待使用者確認範圍", "需決策"],
      ],
      focus: "完成研究背景第一段",
      relation: ["金融科技採用", "信任與風險", "行為意圖"],
    },
    project: {
      eyebrow: "Project workspace",
      title: "NextStep Beta：完整執行閉環",
      description: "以使用者價值切分，從設定目標一路驗證到重新規劃。",
      outputs: [
        ["Today 響應式介面", "iPhone / iPad 合約", "完成"],
        ["Guided Task 垂直切片", "含來源錨點與測驗", "進行中"],
        ["實機 Beta 驗證", "需要 iPhone / iPad", "待排程"],
      ],
      focus: "完成第一個可驗證 Vertical Slice",
      relation: ["目標輸入", "Today 行動", "完成與重排"],
    },
    career: {
      eyebrow: "Career workspace",
      title: "企業金融 MA 求職計畫",
      description: "職缺要求轉成有證據、有完成標準的每日行動。",
      outputs: [
        ["共同能力需求", "3 份職缺交叉比對", "完成"],
        ["授信分析能力段落", "已有 2 個經歷證據", "今天"],
        ["Behavioral 題庫", "4 / 12 題有 STAR 草稿", "進行中"],
      ],
      focus: "完成履歷中的授信分析段落",
      relation: ["職缺要求", "能力證據", "履歷段落"],
    },
  };
  const workspace = workspaces[state.workspace];
  return `
    <section class="screen workspace-screen" aria-labelledby="workspace-title">
      <header class="screen-heading">
        <div><span class="eyebrow">Outcome workspace</span><h1 id="workspace-title">把資料轉成可交付成果。</h1><p>論文、作品與求職共用同一套來源追溯與每日執行邏輯。</p></div>
      </header>
      <nav class="workspace-tabs" aria-label="工作區類型">
        <button type="button" data-workspace="thesis" aria-pressed="${state.workspace === "thesis"}">論文</button>
        <button type="button" data-workspace="project" aria-pressed="${state.workspace === "project"}">作品</button>
        <button type="button" data-workspace="career" aria-pressed="${state.workspace === "career"}">求職</button>
      </nav>
      <div class="workspace-grid">
        <div class="workspace-stack">
          <section class="workspace-card">
            <span class="eyebrow">${workspace.eyebrow}</span>
            <h2>${workspace.title}</h2>
            <p>${workspace.description}</p>
            <div class="badge-row"><span class="badge verified">來源 grounding 開啟</span><span class="badge ai">AI 建議需確認</span></div>
          </section>
          <section class="workspace-card">
            <div class="section-label"><h3>具體產出</h3><span>不是模糊 Todo</span></div>
            <ul class="output-list">
              ${workspace.outputs.map((item, index) => `<li><span class="output-index">0${index + 1}</span><span><strong>${item[0]}</strong><small>${item[1]}</small></span><span class="output-status">${item[2]}</span></li>`).join("")}
            </ul>
          </section>
        </div>
        <aside class="workspace-stack">
          <section class="workspace-card">
            <span class="eyebrow">Next prepared action</span>
            <h3>${workspace.focus}</h3>
            <p>所需材料與完成標準會在 Today 直接展開。</p>
            <button type="button" class="primary-button" data-route="today">回到 Today</button>
          </section>
          <section class="workspace-card">
            <div class="section-label"><h3>脈絡關聯</h3><span>Knowledge links</span></div>
            <div class="knowledge-map" aria-label="知識關聯圖">
              <span class="map-node primary">${workspace.relation[0]}</span><span class="map-node second">${workspace.relation[1]}</span><span class="map-node third">${workspace.relation[2]}</span>
            </div>
          </section>
        </aside>
      </div>
    </section>`;
}

function performAction(action) {
  switch (action) {
    case "start-guided":
      dispatch({ type: "START_GUIDED" });
      focusContent();
      break;
    case "open-replan": {
      const radio = document.querySelector(`input[name="available-time"][value="${state.availableMinutes}"]`);
      if (radio) radio.checked = true;
      proposalDuration.textContent = `${state.availableMinutes} 分鐘`;
      replanDialog.showModal();
      break;
    }
    case "next-step":
      dispatch({ type: "SET_GUIDED_STEP", step: Math.min(3, state.guidedStep + 1) });
      break;
    case "previous-step":
      dispatch({ type: "SET_GUIDED_STEP", step: Math.max(0, state.guidedStep - 1) });
      break;
    case "open-paper":
      dispatch({ type: "NAVIGATE", route: "paper" });
      focusContent();
      break;
    case "complete-task":
      dispatch({ type: "COMPLETE_TASK" });
      showToast("任務完成：進度與下一步已更新。 ");
      focusContent();
      break;
    case "source-demo":
      showToast("正式 App 會開啟本機原檔；此 contract preview 不連外、不存取你的檔案。 ");
      break;
    default:
      break;
  }
}

function focusContent() {
  requestAnimationFrame(() => content.focus({ preventScroll: true }));
}

function showToast(message) {
  window.clearTimeout(toastTimer);
  toast.textContent = message;
  toast.classList.add("visible");
  toastTimer = window.setTimeout(() => toast.classList.remove("visible"), 3200);
}
