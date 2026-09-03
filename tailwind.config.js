/** @type {import('tailwindcss').Config} */
module.exports = {
  // Only app/ contains JSX. The old config also globbed ./lib/**, which walks the vendored
  // Foundry sources on every build for zero matches.
  content: ["./app/**/*.{js,jsx}", "./components/**/*.{js,jsx}"],
  theme: {
    extend: {
      // Colours resolve through CSS custom properties declared in globals.css, so light and
      // dark are handled once at the token level instead of dark: variants on every element.
      colors: {
        paper: "var(--paper)",
        surface: "var(--surface)",
        raised: "var(--raised)",
        ink: "var(--ink)",
        "ink-soft": "var(--ink-soft)",
        muted: "var(--muted)",
        rule: "var(--rule)",
        "rule-soft": "var(--rule-soft)",
        accent: "var(--accent)",
        "accent-soft": "var(--accent-soft)",
        // Semantic state colours, deliberately separate from the accent: these carry pool
        // status (healthy / alerted / paused) and nothing else.
        ok: "var(--ok)",
        warn: "var(--warn)",
        stop: "var(--stop)",
        "ok-bg": "var(--ok-bg)",
        "warn-bg": "var(--warn-bg)",
        "stop-bg": "var(--stop-bg)"
      },
      fontFamily: {
        sans: ["Archivo", "ui-sans-serif", "system-ui", "sans-serif"],
        serif: ["Source Serif 4", "Georgia", "Times New Roman", "serif"],
        mono: ["JetBrains Mono", "ui-monospace", "SFMono-Regular", "Consolas", "monospace"]
      },
      letterSpacing: {
        label: "0.12em"
      }
    }
  },
  plugins: []
};
