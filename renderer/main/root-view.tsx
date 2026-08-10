import { Outlet } from "@tanstack/react-router";
import { useQueryClient } from "@tanstack/react-query";
import * as React from "react";
import { Status } from "@glaze/core/components";
import { useTheme, useConnection, useEnvironment } from "@glaze/core/hooks";

import type { AgentMonitorState } from "../lib/agents";
import type { HistoryStats } from "../lib/history";

export function RootView() {
  useTheme();

  const connectionQuery = useConnection();
  const environmentQuery = useEnvironment();
  const queryClient = useQueryClient();

  React.useEffect(() => {
    // Push backend broadcasts straight into the query cache so both tabs stay live.
    const offAgents = window.glazeAPI.glaze.ipc.onNotification(
      "agents:state-changed",
      (params: unknown) => {
        queryClient.setQueryData(["agentState"], params as AgentMonitorState);
        // The in-progress awake session ticks with each scan; refresh stats when observed.
        void queryClient.invalidateQueries({ queryKey: ["historyStats"] });
      },
    );

    const offHistory = window.glazeAPI.glaze.ipc.onNotification(
      "history:changed",
      (params: unknown) => {
        queryClient.setQueryData(["historyStats"], params as HistoryStats);
      },
    );

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      event.preventDefault();
      void window.glazeAPI.glaze.ipc.invoke("window:hidePanel");
    };
    window.addEventListener("keydown", onKeyDown);

    return () => {
      offAgents();
      offHistory();
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [queryClient]);

  React.useEffect(() => {
    return () => {
      window.glazeAPI?.glaze?.ipc?.disconnect();
    };
  }, []);

  return (
    <div className="relative h-full bg-transparent [&:not(:has([data-toolbar]))_.drag-region]:z-50">
      <div className="drag-region fixed top-0 right-0 left-0 h-13" />
      <Outlet />

      {import.meta.env.DEV ? (
        <div className="fixed right-2 bottom-2 z-50 flex flex-col items-end gap-1">
          {connectionQuery.error ? <Status variant="error">Backend disconnected</Status> : null}
          {environmentQuery.data ? null : <Status variant="error">Dev Server not found</Status>}
        </div>
      ) : null}
    </div>
  );
}
