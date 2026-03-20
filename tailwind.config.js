module.exports = {
  content: [
    "./app/**/*.{js,jsx}",
    "./components/**/*.{js,jsx}",
    "./lib/**/*.{js,jsx}"
  ],
  theme: {
    extend: {
      colors: {
        signal: {
          ink: "#0f172a",
          mist: "#e2e8f0",
          accent: "#ea580c",
          safe: "#15803d",
          alert: "#b91c1c"
        }
      },
      boxShadow: {
        panel: "0 20px 45px rgba(15, 23, 42, 0.12)"
      }
    }
  },
  plugins: []
};
