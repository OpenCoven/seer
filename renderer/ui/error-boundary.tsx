import type { ErrorComponentProps } from "@tanstack/react-router";

import { Button, Text } from "./primitives";

/**
 * Route-level error boundary rendered by TanStack Router's `errorComponent`.
 * Seer-owned replacement for Glaze's `ErrorBoundaryView` — no Glaze imports.
 */
export function RouteErrorBoundary({ error, reset }: ErrorComponentProps) {
  const message = error instanceof Error ? error.message : "An unexpected error occurred.";

  return (
    <div role="alert" className="flex h-full flex-col items-center justify-center gap-3 px-6 py-8 text-center">
      <div className="flex flex-col gap-1">
        <Text variant="strong">Something went wrong</Text>
        <Text variant="small" color="secondary">
          {message}
        </Text>
      </div>
      <Button variant="muted" size="small" onClick={() => reset()}>
        Try again
      </Button>
    </div>
  );
}
