import glazeConfig from "./.glaze-core/cli/lint/eslint.config.js";
import globals from "globals";

export default [
  {
    ignores: ["apps/macos/Seer/build/**"],
  },
  ...glazeConfig,
  {
    files: ["scripts/**/*.mjs", "tests/**/*.mjs"],
    languageOptions: {
      globals: {
        ...globals.node,
      },
    },
    rules: {
      "no-unused-vars": [
        "warn",
        {
          argsIgnorePattern: "^_+",
          varsIgnorePattern: "^_+",
          ignoreRestSiblings: true,
          caughtErrors: "none",
        },
      ],
      "no-unsafe-finally": "warn",
    },
  },
];
