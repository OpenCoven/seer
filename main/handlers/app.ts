import { logger } from "@glaze/core/backend";

export const appHandlers = {
  getInfo: async () => {
    logger.info("app", "App info requested");
    return {
      name: "Seer",
      version: "1.0.0",
      environment: process.env.NODE_ENV || "production",
    };
  },
};
