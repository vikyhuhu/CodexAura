// CodexAura renderer payload — idempotent, self-cleaning, CSS-variable driven.
// Placeholders are substituted by PayloadBuilder with JSON string literals.
((__css, __art, __theme) => {
  "use strict";
  // Kill-switch: restore sets this flag; orphan addScriptToEvaluateOnNewDocument
  // copies registered by previous app runs (a new process cannot remove them)
  // must no-op here instead of resurrecting the skin after "还原官方外观".
  try { if (localStorage.getItem("codexaura:disabled") === "1") return false; } catch (e) {}

  const STATE_KEY = "__CODEX_AURA_STATE__";
  const ROOT_CLASS = "codex-aura";
  const STYLE_ID = "codex-aura-style";

  const removeStyle = () => document.getElementById(STYLE_ID)?.remove();
  const cleanupRoot = (root) => {
    root.classList.remove(ROOT_CLASS);
    root.classList.remove("aura-bordered");
    for (const name of (window[STATE_KEY]?.vars ?? [])) root.style.removeProperty(name);
  };

  // Clean up any previous injection before applying a new one.
  try {
    if (window[STATE_KEY]?.cleanup) window[STATE_KEY].cleanup();
    else { removeStyle(); cleanupRoot(document.documentElement); }
  } catch {}

  const root = document.documentElement;
  if (!root) return false; // document-start before <html> exists

  // Live tweaks (dim / blur / content mask / bordered) are mirrored to localStorage by the host
  // app so reloads replay them. Tweaks are owned by a theme id: stale or foreign
  // entries (previous theme, previous app run) are dropped, never replayed.
  const TWEAKS_KEY = "codexaura:tweaks";
  let tweaks = {};
  try { tweaks = JSON.parse(localStorage.getItem(TWEAKS_KEY) ?? "{}") || {}; } catch (e) {}
  if (tweaks["aura-theme-id"] !== (__theme && __theme.id)) {
    if (Object.keys(tweaks).length > 0) { try { localStorage.removeItem(TWEAKS_KEY); } catch (e) {} }
    tweaks = {};
  }
  const colors = (__theme && typeof __theme === "object" && __theme.colors) || {};
  const hexToRgb = (hex) => {
    const m = /^#([0-9a-f]{6})$/i.exec(String(hex ?? "").trim());
    if (!m) return null;
    const n = parseInt(m[1], 16);
    return `${(n >> 16) & 255} ${(n >> 8) & 255} ${n & 255}`;
  };

  const vars = {
    "--aura-image": `url("${__art}")`,
    "--aura-focus": `${Math.round((__theme.focusX ?? 0.5) * 100)}% ${Math.round((__theme.focusY ?? 0.5) * 100)}%`,
    "--aura-dim": String(__theme.dim ?? 0.35),
    "--aura-blur": `${Number(__theme.blur ?? 0)}px`,
    "--aura-content-mask": String(__theme.contentMask ?? 1),
    "--aura-bg": colors.background ?? "#101216",
    "--aura-panel": colors.panel ?? "#171a20",
    "--aura-accent": colors.accent ?? "#7aa2f7",
    "--aura-text": colors.text ?? "#e8eaee",
    "--aura-muted": colors.muted ?? "#9aa0aa",
    "--aura-line": colors.line ?? "rgba(255,255,255,.14)",
    "--aura-on-accent": colors.onAccent ?? "#000000",
    "--aura-scrim-rgb": __theme.scrimRGB ?? "0 0 0",
    "--aura-color-scheme": __theme.colorScheme ?? "dark",
    "--aura-bg-rgb": hexToRgb(colors.background) ?? "16 18 22",
    "--aura-panel-rgb": hexToRgb(colors.panel) ?? "23 26 32",
    "--aura-accent-rgb": hexToRgb(colors.accent) ?? "122 162 247",
    "--aura-text-rgb": hexToRgb(colors.text) ?? "232 234 238",
    // 首页标题下方的签名行（CSS content 用，需要带引号的字符串值）
    "--aura-tagline": JSON.stringify(String(__theme.tagline ?? "")),
  };

  // Persisted live tweaks override the theme defaults (same theme only — see above).
  for (const [name, value] of Object.entries(tweaks)) {
    if (name.startsWith("--aura-") && typeof value === "string") vars[name] = value;
  }
  const borderedPref = tweaks["aura-bordered"];

  root.classList.add(ROOT_CLASS);
  root.classList.toggle("aura-bordered", borderedPref === undefined ? Boolean(__theme.bordered) : Boolean(borderedPref));
  const applied = [];
  for (const [name, value] of Object.entries(vars)) {
    root.style.setProperty(name, value);
    applied.push(name);
  }

  const style = document.createElement("style");
  style.id = STYLE_ID;
  style.textContent = __css;
  (document.head ?? document.documentElement).appendChild(style);

  window[STATE_KEY] = {
    version: 1,
    themeId: __theme.id ?? null,
    vars: applied,
    cleanup() {
      removeStyle();
      cleanupRoot(root);
      delete window[STATE_KEY];
      return true;
    },
  };
  return true;
})(__AURA_CSS_JSON__, __AURA_ART_JSON__, __AURA_THEME_JSON__)
