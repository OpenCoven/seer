// @ts-check
import js from "@eslint/js";
import tsParser from "@typescript-eslint/parser";
import tsPlugin from "@typescript-eslint/eslint-plugin";
import globals from "globals";

/**
 * Lint config for the standalone-safe surface of the renderer: shared
 * renderer code, the standalone entry point, and the standalone build
 * config. Deliberately scoped so it never needs the Glaze SDK's private
 * ambient types (no `.glaze-core` project reference, no `@glaze/core/*`
 * path resolution) — only already-installed `@eslint/js` +
 * `typescript-eslint` parser/plugin + browser globals, no new dependencies.
 */
export default [
  {
    ignores: ["node_modules/**", "build/**", "renderer/preload.ts", "renderer/dev/**"],
  },
  js.configs.recommended,
  {
    files: ["**/*.{ts,tsx}"],
    languageOptions: {
      parser: tsParser,
      parserOptions: {
        ecmaFeatures: { jsx: true },
        sourceType: "module",
      },
      globals: {
        ...globals.browser,
      },
    },
    plugins: {
      "@typescript-eslint": tsPlugin,
    },
    rules: {
      ...tsPlugin.configs.recommended.rules,
      "no-unused-vars": "off",
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
    },
  },
];
