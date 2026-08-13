import glazeConfig from "./.glaze-core/cli/lint/eslint.config.js";

export default [
  {
    ignores: ["apps/macos/Seer/build/**"],
  },
  ...glazeConfig,
];
