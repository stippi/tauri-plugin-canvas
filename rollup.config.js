import typescript from "@rollup/plugin-typescript";

export default {
  input: "guest-js/index.ts",
  output: [
    {
      file: "dist-js/index.js",
      format: "es",
      sourcemap: true,
    },
    {
      file: "dist-js/index.cjs",
      format: "cjs",
      sourcemap: true,
    },
  ],
  plugins: [
    typescript({
      declaration: true,
      declarationDir: "dist-js",
      rootDir: "guest-js",
      outDir: "dist-js",
    }),
  ],
  external: ["@tauri-apps/api/core", "@tauri-apps/api/event"],
};
