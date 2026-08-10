import { Outlet } from "@tanstack/react-router";
import { useQuery, useQueryClient, type QueryClient, type UseQueryResult } from "@tanstack/react-query";
import * as React from "react";

import { useRendererBridge } from "../bridge/renderer-bridge-context";
import type { AppSnapshot, Diagnostic } from "../bridge/types";
import { Badge } from "../ui/primitives";

/** The single query key every view reads the app's live snapshot from. */
export const APP_SNAPSHOT_QUERY_KEY = ["appSnapshot"] as const;

/**
 * Writes a complete `AppSnapshot` (returned by a bridge mutation, or pushed
 * via `bridge.subscribe`) straight into the shared query cache. Every
 * mutation across the app (`setKeepAwakeMode`, `clearHistory`, ...) funnels
 * its result through this one function so there is a single place that
 * defines what "the app's current snapshot" means.
 */
export function writeAppSnapshot(queryClient: QueryClient, snapshot: AppSnapshot): void {
  queryClient.setQueryData(APP_SNAPSHOT_QUERY_KEY, snapshot);
}

/**
 * Shared read hook for the app's current `AppSnapshot`. `RootView` is the
 * component responsible for keeping this query's cache entry fresh (initial
 * fetch + live `bridge.subscribe` pushes); every other view just selects the
 * slice it needs from the same cached entry via this hook.
 */
export function useAppSnapshot(): UseQueryResult<AppSnapshot> {
  const bridge = useRendererBridge();
  return useQuery({
    queryKey: APP_SNAPSHOT_QUERY_KEY,
    queryFn: () => bridge.getSnapshot(),
  });
}

/**
 * Pure: whether a keydown event should trigger the panel-hide operation.
 * Extracted from the keydown listener so this decision is unit-testable
 * without a DOM/React rendering environment.
 */
export function isPanelHideKeydown(event: Pick<KeyboardEvent, "key" | "defaultPrevented">): boolean {
  return event.key === "Escape" && !event.defaultPrevented;
}

/** Pure: the diagnostics to render, given the (possibly not-yet-loaded) snapshot. */
export function selectDiagnostics(snapshot: AppSnapshot | undefined): Diagnostic[] {
  return snapshot?.diagnostics ?? [];
}

export function RootView() {
  const bridge = useRendererBridge();
  const queryClient = useQueryClient();
  const { data: snapshot } = useAppSnapshot();

  React.useEffect(() => {
    // The bridge always delivers complete, cloned snapshots (both the Glaze
    // and standalone adapters merge partial backend updates internally), so
    // this can write the cache directly with no further merging here.
    const unsubscribe = bridge.subscribe((next) => {
      writeAppSnapshot(queryClient, next);
    });

    const onKeyDown = (event: KeyboardEvent) => {
      if (!isPanelHideKeydown(event)) return;
      event.preventDefault();
      void bridge.hidePanel();
    };
    window.addEventListener("keydown", onKeyDown);

    return () => {
      unsubscribe();
      window.removeEventListener("keydown", onKeyDown);
    };
  }, [bridge, queryClient]);

  React.useEffect(() => {
    return () => {
      bridge.disconnect();
    };
  }, [bridge]);

  const diagnostics = selectDiagnostics(snapshot);

  return (
    <div className="relative h-full bg-transparent [&:not(:has([data-toolbar]))_.drag-region]:z-50">
      <div className="drag-region fixed top-0 right-0 left-0 h-13" />
      <Outlet />

      {diagnostics.length > 0 ? (
        <div
          role="status"
          className="fixed right-2 bottom-2 z-50 flex flex-col items-end gap-1"
        >
          {diagnostics.map((diagnostic) => (
            <Badge key={diagnostic.id} color="secondary">
              {diagnostic.message}
            </Badge>
          ))}
        </div>
      ) : null}
    </div>
  );
}

