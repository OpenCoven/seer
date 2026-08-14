import { getSharedUpdateService } from "../services/update-check.js";

export const updateHandlers = {
  getState: () => getSharedUpdateService().getState(),
  check: () => getSharedUpdateService().check({ force: true }),
  open: () => getSharedUpdateService().openCurrentRelease(),
};
