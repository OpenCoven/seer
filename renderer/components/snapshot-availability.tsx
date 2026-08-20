import type { ReactNode } from "react";

import { EmptyState } from "../ui/primitives";

export function SnapshotAvailability({
  isPending,
  loadingTitle,
  errorTitle,
  errorDescription,
  media,
}: {
  isPending: boolean;
  loadingTitle: string;
  errorTitle: string;
  errorDescription: string;
  media: ReactNode;
}) {
  return (
    <div
      role={isPending ? "status" : "alert"}
      aria-live={isPending ? "polite" : "assertive"}
      className="relative min-h-60 px-3 pt-1 pb-3"
    >
      <EmptyState
        placement="center"
        title={isPending ? loadingTitle : errorTitle}
        description={isPending ? "Waiting for the first app snapshot…" : errorDescription}
        media={media}
      />
    </div>
  );
}
